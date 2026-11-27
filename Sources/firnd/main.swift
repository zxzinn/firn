import Darwin
import Foundation
import FirnCore

private final class DaemonState {
    let runner: any VMBackend
    let bridge: VsockBridge
    let balloon: BalloonController
    let dnsServer: LocalDNSServer
    let autoThaw: AutoThawProxy
    let httpsProxy: HTTPSDomainProxy?
    let hostNet: HostNetSupervisor?
    let fsWatcher: FSEventsWatcher?
    let stopSemaphore = DispatchSemaphore(value: 0)
    var hostServer: HostControlServer?
    var proxyWatcher: ProxyWatcher?
    var termSrc: DispatchSourceSignal?
    var intSrc: DispatchSourceSignal?

    init(
        runner: any VMBackend,
        bridge: VsockBridge,
        balloon: BalloonController,
        dnsServer: LocalDNSServer,
        autoThaw: AutoThawProxy,
        httpsProxy: HTTPSDomainProxy?,
        hostNet: HostNetSupervisor?,
        fsWatcher: FSEventsWatcher?
    ) {
        self.runner = runner
        self.bridge = bridge
        self.balloon = balloon
        self.dnsServer = dnsServer
        self.autoThaw = autoThaw
        self.httpsProxy = httpsProxy
        self.hostNet = hostNet
        self.fsWatcher = fsWatcher
    }
}

func cleanupAndExit(
    fsWatcher: FSEventsWatcher?,
    httpsProxy: HTTPSDomainProxy?,
    autoThaw: AutoThawProxy,
    dnsServer: LocalDNSServer,
    bridge: VsockBridge,
    hostNet: HostNetSupervisor?,
    code: Int32 = 0
) -> Never {
    fsWatcher?.stop()
    httpsProxy?.stop()
    autoThaw.stop()
    dnsServer.stop()
    bridge.stop()
    hostNet?.stop()
    try? FileManager.default.removeItem(at: FirnPaths.pidFileURL)
    exit(code)
}

private func shutdownVMAndExit(state: DaemonState) -> Never {
    state.hostServer?.stop()
    if !state.runner.isHibernated {
        // Ask guest PID 1 via firn-guestd to flush buffers, fstrim, and remount rootfs read-only.
        _ = try? state.bridge.guestHTTP(method: "POST", path: "/poweroff", timeoutSeconds: 2.0)
        if state.stopSemaphore.wait(timeout: .now() + 6.0) == .timedOut {
            state.runner.stopGracefully(timeoutSeconds: 4.0)
        }
    }
    cleanupAndExit(
        fsWatcher: state.fsWatcher,
        httpsProxy: state.httpsProxy,
        autoThaw: state.autoThaw,
        dnsServer: state.dnsServer,
        bridge: state.bridge,
        hostNet: state.hostNet,
        code: 0
    )
}

private func pushGuestConfigAndProxy(bridge: VsockBridge, cfg: FirnConfig, proxyState: HostProxyState?) {
    DispatchQueue.global(qos: .utility).async {
        let payload: [String: Any] = [
            "idleSeconds": cfg.idleSeconds,
            "domain": cfg.domain,
            "exemptProjects": cfg.exemptProjects,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        for _ in 0..<60 {
            if let (code, _) = try? bridge.guestHTTP(method: "POST", path: "/config", body: body, timeoutSeconds: 2.0), code < 300 {
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if let proxyState, let pBody = try? JSONEncoder().encode(proxyState) {
            _ = try? bridge.guestHTTP(method: "POST", path: "/proxy-config", body: pBody, timeoutSeconds: 2.0)
        }
    }
}

func runDaemon() throws {
    signal(SIGPIPE, SIG_IGN)
    signal(SIGHUP, SIG_IGN)

    let cfg = FirnConfig.load()
    try FileManager.default.createDirectory(at: FirnPaths.runDir, withIntermediateDirectories: true)
    try String(ProcessInfo.processInfo.processIdentifier).write(to: FirnPaths.pidFileURL, atomically: true, encoding: .utf8)

    let hostNet = HostNetSupervisor(config: cfg)
    let useKrun = (cfg.backend == "krun") || cfg.gpu
    let runner: any VMBackend = useKrun
        ? KrunMachineRunner(config: cfg)
        : VZMachineRunner(config: cfg, useFastNet: hostNet != nil)

    let bridge = VsockBridge(runner: runner)
    let balloon = BalloonController(runner: runner, bridge: bridge)
    let dnsServer = LocalDNSServer(port: cfg.dnsPort, domain: cfg.domain)
    let autoThaw = AutoThawProxy(
        bridge: bridge,
        balloon: balloon,
        dnsServer: dnsServer,
        httpProxyPort: cfg.httpProxyPort,
        hostNet: hostNet,
        delegateProxying: hostNet != nil,
        isHibernatedCheck: { [weak runner] in runner?.isHibernated ?? false }
    )
    let httpsProxy: HTTPSDomainProxy? = hostNet == nil
        ? HTTPSDomainProxy(autoThaw: autoThaw, dnsServer: dnsServer, domain: cfg.domain, httpsPort: cfg.httpsProxyPort)
        : nil

    let fsWatcher: FSEventsWatcher? = hostNet != nil
        ? FSEventsWatcher { relPaths in
            hostNet?.pushFSEvents(relPaths)
        }
        : nil

    let state = DaemonState(
        runner: runner,
        bridge: bridge,
        balloon: balloon,
        dnsServer: dnsServer,
        autoThaw: autoThaw,
        httpsProxy: httpsProxy,
        hostNet: hostNet,
        fsWatcher: fsWatcher
    )

    autoThaw.onProjectsChanged = { projects in
        httpsProxy?.reloadCertificates(projects: projects)
    }

    var hostNetRunning = false
    if let hostNet {
        do {
            try hostNet.start()
            hostNetRunning = true
            hostNet.pushDNSServers(VsockBridge.currentMacOSDNSServers())
        } catch {
            fputs("[firnd] warning: firn-hostnet failed to start (\(error.localizedDescription)); falling back to VZ NAT\n", stderr)
            fflush(stderr)
        }
    }

    runner.onVMNetSocketPairReady = { fd in
        if hostNetRunning, let hostNet {
            do {
                try hostNet.sendVMNetSocketFD(fd)
            } catch {
                fputs("[firnd] failed passing vmnet fd to firn-hostnet: \(error.localizedDescription)\n", stderr)
                fflush(stderr)
            }
        } else {
            Darwin.close(fd)
        }
    }

    runner.onPrepareHibernate = {
        _ = try? bridge.guestHTTP(method: "POST", path: "/poweroff", timeoutSeconds: 2.0)
    }
    runner.onResumeFromHibernate = {
        let liveCfg = FirnConfig.load()
        pushGuestConfigAndProxy(bridge: bridge, cfg: liveCfg, proxyState: ProxyInspector.currentState())
        autoThaw.pushHibernatedTopology(hibernated: false)
        autoThaw.syncTopologyNow()
    }

    do {
        var hostServer: HostControlServer!
        hostServer = HostControlServer(
            runner: runner,
            bridge: bridge,
            balloon: balloon,
            autoThaw: autoThaw,
            httpsProxy: httpsProxy,
            dnsServer: dnsServer,
            hostNet: hostNetRunning ? hostNet : nil
        ) {
            shutdownVMAndExit(state: state)
        }
        try hostServer.start()
        state.hostServer = hostServer

        try runner.start()
        bridge.startHostRelays()
        try bridge.startDockerSocketBridge()
        try bridge.startShellSocketBridge()
        try dnsServer.start()
        autoThaw.start()
        try? httpsProxy?.start()
        fsWatcher?.start()

        runner.onStop = { (error: Error?) in
            state.stopSemaphore.signal()
            if let error {
                fputs("[firnd] VM stopped with error: \(error.localizedDescription)\n", stderr)
                fflush(stderr)
            }
            hostServer.stop()
            cleanupAndExit(
                fsWatcher: fsWatcher,
                httpsProxy: httpsProxy,
                autoThaw: autoThaw,
                dnsServer: dnsServer,
                bridge: bridge,
                hostNet: hostNet,
                code: error == nil ? 0 : 1
            )
        }

        pushGuestConfigAndProxy(bridge: bridge, cfg: cfg, proxyState: nil)

        let proxyWatcher = ProxyWatcher { proxyState in
            hostServer.updateProxyState(proxyState)
            if hostNetRunning {
                hostNet?.pushDNSServers(VsockBridge.currentMacOSDNSServers())
            }
            if !runner.isHibernated {
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
        }
        proxyWatcher.start()
        state.proxyWatcher = proxyWatcher

        // Safety balloon expansion, periodic idle trim, and optional total-idle VM hibernate.
        DispatchQueue.global(qos: .utility).async {
            var tick = 0
            var idleAllStoppedSince: Date?
            while true {
                Thread.sleep(forTimeInterval: 15.0)
                tick += 1
                if runner.isHibernated {
                    idleAllStoppedSince = nil
                    continue
                }
                if let (status, data) = try? bridge.guestHTTP(method: "GET", path: "/status", timeoutSeconds: 2.0),
                   status == 200,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if runner.getBalloonTargetBytes() < cfg.maxMemoryBytes,
                       let vmMem = obj["vmMemory"] as? [String: Any],
                       let available = (vmMem["availableBytes"] as? NSNumber)?.uint64Value,
                       available < cfg.minBalloonBytes {
                        runner.setBalloonTargetBytes(cfg.maxMemoryBytes)
                    } else if tick % 4 == 0 {
                        balloon.periodicIdleTrimIfHelpful()
                    }

                    let currentCfg = FirnConfig.load()
                    if currentCfg.hibernateSeconds > 0 {
                        let projects = (obj["projects"] as? [[String: Any]]) ?? []
                        let anyActive = projects.contains { (($0["runningCount"] as? Int) ?? 0) > 0 }
                        let k3sRunning = ((obj["capabilities"] as? [String: Any])?["k3sRunning"] as? Bool) ?? false
                        let sessions = bridge.activeSessionCount + autoThaw.activeSessionCount
                        if !anyActive && !k3sRunning && sessions == 0 {
                            if idleAllStoppedSince == nil {
                                idleAllStoppedSince = Date()
                            } else if Date().timeIntervalSince(idleAllStoppedSince!) >= Double(currentCfg.hibernateSeconds) {
                                fputs("[firnd] auto-hibernating VM after \(currentCfg.hibernateSeconds)s idle...\n", stderr)
                                fflush(stderr)
                                do {
                                    _ = try runner.hibernate()
                                    autoThaw.pushHibernatedTopology(hibernated: true)
                                    idleAllStoppedSince = nil
                                } catch {
                                    fputs("[firnd] auto-hibernate failed: \(error.localizedDescription)\n", stderr)
                                    fflush(stderr)
                                }
                            }
                        } else {
                            idleAllStoppedSince = nil
                        }
                    }
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
        cleanupAndExit(
            fsWatcher: fsWatcher,
            httpsProxy: httpsProxy,
            autoThaw: autoThaw,
            dnsServer: dnsServer,
            bridge: bridge,
            hostNet: hostNet,
            code: 1
        )
    }
}

try runDaemon()
