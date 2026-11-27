import Darwin
import Foundation
import FirnCore

private final class DaemonState {
    let runner: VZMachineRunner
    let bridge: VsockBridge
    let balloon: BalloonController
    let dnsServer: LocalDNSServer
    let autoThaw: AutoThawProxy
    let httpsProxy: HTTPSDomainProxy
    let stopSemaphore = DispatchSemaphore(value: 0)
    var hostServer: HostControlServer?
    var proxyWatcher: ProxyWatcher?
    var termSrc: DispatchSourceSignal?
    var intSrc: DispatchSourceSignal?

    init(
        runner: VZMachineRunner,
        bridge: VsockBridge,
        balloon: BalloonController,
        dnsServer: LocalDNSServer,
        autoThaw: AutoThawProxy,
        httpsProxy: HTTPSDomainProxy
    ) {
        self.runner = runner
        self.bridge = bridge
        self.balloon = balloon
        self.dnsServer = dnsServer
        self.autoThaw = autoThaw
        self.httpsProxy = httpsProxy
    }
}

func cleanupAndExit(
    httpsProxy: HTTPSDomainProxy,
    autoThaw: AutoThawProxy,
    dnsServer: LocalDNSServer,
    bridge: VsockBridge,
    code: Int32 = 0
) -> Never {
    httpsProxy.stop()
    autoThaw.stop()
    dnsServer.stop()
    bridge.stop()
    try? FileManager.default.removeItem(at: FirnPaths.pidFileURL)
    exit(code)
}

private func shutdownVMAndExit(state: DaemonState) -> Never {
    state.hostServer?.stop()
    // Ask guest PID 1 via firn-guestd to flush buffers, fstrim, and remount rootfs read-only.
    _ = try? state.bridge.guestHTTP(method: "POST", path: "/poweroff", timeoutSeconds: 2.0)
    if state.stopSemaphore.wait(timeout: .now() + 6.0) == .timedOut {
        state.runner.stopGracefully()
    }
    cleanupAndExit(
        httpsProxy: state.httpsProxy,
        autoThaw: state.autoThaw,
        dnsServer: state.dnsServer,
        bridge: state.bridge,
        code: 0
    )
}

func runDaemon() throws {
    signal(SIGPIPE, SIG_IGN)
    signal(SIGHUP, SIG_IGN)

    let cfg = FirnConfig.load()
    let runner = VZMachineRunner(config: cfg)
    let bridge = VsockBridge(runner: runner)
    let balloon = BalloonController(runner: runner, bridge: bridge)
    let dnsServer = LocalDNSServer(port: cfg.dnsPort, domain: cfg.domain)
    let autoThaw = AutoThawProxy(bridge: bridge, balloon: balloon, dnsServer: dnsServer, httpProxyPort: cfg.httpProxyPort)
    let httpsProxy = HTTPSDomainProxy(autoThaw: autoThaw, dnsServer: dnsServer, domain: cfg.domain, httpsPort: cfg.httpsProxyPort)
    let state = DaemonState(
        runner: runner,
        bridge: bridge,
        balloon: balloon,
        dnsServer: dnsServer,
        autoThaw: autoThaw,
        httpsProxy: httpsProxy
    )

    autoThaw.onProjectsChanged = { projects in
        httpsProxy.reloadCertificates(projects: projects)
    }

    try FileManager.default.createDirectory(at: FirnPaths.runDir, withIntermediateDirectories: true)
    try String(ProcessInfo.processInfo.processIdentifier).write(to: FirnPaths.pidFileURL, atomically: true, encoding: .utf8)

    do {
        try runner.start()
        bridge.startHostRelays()
        try bridge.startDockerSocketBridge()
        try bridge.startShellSocketBridge()
        try dnsServer.start()
        autoThaw.start()
        try? httpsProxy.start()

        var hostServer: HostControlServer!
        hostServer = HostControlServer(
            runner: runner,
            bridge: bridge,
            balloon: balloon,
            autoThaw: autoThaw,
            httpsProxy: httpsProxy,
            dnsServer: dnsServer
        ) {
            shutdownVMAndExit(state: state)
        }
        try hostServer.start()
        state.hostServer = hostServer

        runner.onStop = { (error: Error?) in
            state.stopSemaphore.signal()
            if let error {
                fputs("[firnd] VM stopped with error: \(error.localizedDescription)\n", stderr)
                fflush(stderr)
            }
            hostServer.stop()
            cleanupAndExit(httpsProxy: httpsProxy, autoThaw: autoThaw, dnsServer: dnsServer, bridge: bridge, code: error == nil ? 0 : 1)
        }

        // Push host FirnConfig (idleSeconds, domain, exemptProjects) to firn-guestd once ready.
        DispatchQueue.global(qos: .utility).async {
            let payload: [String: Any] = [
                "idleSeconds": cfg.idleSeconds,
                "domain": cfg.domain,
                "exemptProjects": cfg.exemptProjects,
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
            for _ in 0..<60 {
                if let (code, _) = try? bridge.guestHTTP(method: "POST", path: "/config", body: body, timeoutSeconds: 2.0), code < 300 {
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }

        let proxyWatcher = ProxyWatcher { proxyState in
            hostServer.updateProxyState(proxyState)
            DispatchQueue.global(qos: .utility).async {
                guard let body = try? JSONEncoder().encode(proxyState) else { return }
                for _ in 0..<20 {
                    if let (code, _) = try? bridge.guestHTTP(method: "POST", path: "/proxy-config", body: body, timeoutSeconds: 2.0), code < 300 {
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
        }
        proxyWatcher.start()
        state.proxyWatcher = proxyWatcher

        // Lightweight safety expansion + periodic idle balloon trim.
        DispatchQueue.global(qos: .utility).async {
            var tick = 0
            while true {
                Thread.sleep(forTimeInterval: 15.0)
                tick += 1
                if runner.getBalloonTargetBytes() < cfg.maxMemoryBytes,
                   let (status, data) = try? bridge.guestHTTP(method: "GET", path: "/status", timeoutSeconds: 2.0), status == 200,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let vmMem = obj["vmMemory"] as? [String: Any],
                   let available = (vmMem["availableBytes"] as? NSNumber)?.uint64Value,
                   available < cfg.minBalloonBytes {
                    runner.setBalloonTargetBytes(cfg.maxMemoryBytes)
                } else if tick % 4 == 0 {
                    balloon.periodicIdleTrimIfHelpful()
                }
            }
        }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let termSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termSrc.setEventHandler {
            shutdownVMAndExit(state: state)
        }
        termSrc.resume()
        state.termSrc = termSrc
        let intSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        intSrc.setEventHandler {
            shutdownVMAndExit(state: state)
        }
        intSrc.resume()
        state.intSrc = intSrc

        withExtendedLifetime(state) {
            RunLoop.main.run()
        }
    } catch {
        fputs("[firnd] fatal: \(error.localizedDescription)\n", stderr)
        fflush(stderr)
        cleanupAndExit(httpsProxy: httpsProxy, autoThaw: autoThaw, dnsServer: dnsServer, bridge: bridge, code: 1)
    }
}

try runDaemon()
