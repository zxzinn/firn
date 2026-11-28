import Darwin
import Foundation
import FirnCore

private let cleanupExitLock = NSLock()

private final class DaemonState {
    let runner: any VMBackend
    let bridge: VsockBridge
    let balloon: BalloonController
    let dnsServer: LocalDNSServer
    let autoThaw: AutoThawProxy
    let httpsProxy: HTTPSDomainProxy?
    let hostNet: HostNetSupervisor?
    let fsWatcher: FSEventsWatcher?
    let lockFD: Int32
    let stopSemaphore = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var _shuttingDown = false
    var hostServer: HostControlServer?
    var proxyWatcher: ProxyWatcher?
    var pressureGuard: MemoryPressureGuard?
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
        fsWatcher: FSEventsWatcher?,
        lockFD: Int32
    ) {
        self.runner = runner
        self.bridge = bridge
        self.balloon = balloon
        self.dnsServer = dnsServer
        self.autoThaw = autoThaw
        self.httpsProxy = httpsProxy
        self.hostNet = hostNet
        self.fsWatcher = fsWatcher
        self.lockFD = lockFD
    }

    func beginShutdown() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if _shuttingDown { return false }
        _shuttingDown = true
        return true
    }
}

private func acquireDaemonSingletonLock() throws -> Int32 {
    try FileManager.default.createDirectory(at: FirnPaths.runDir, withIntermediateDirectories: true)
    let lockPath = FirnPaths.lockFileURL.path
    let fd = Darwin.open(lockPath, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK, 0o600)
    guard fd >= 0 else {
        let lockErr = errno
        if lockErr == EWOULDBLOCK || lockErr == EAGAIN {
            let existing = (try? String(contentsOf: FirnPaths.lockFileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (try? String(contentsOf: FirnPaths.pidFileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "unknown"
            fputs("[firnd] another firnd instance is already running (pid=\(existing)); exiting cleanly.\n", stderr)
            fflush(stderr)
            exit(0)
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(lockErr), userInfo: [NSLocalizedDescriptionKey: "Cannot lock \(lockPath)"])
    }
    _ = Darwin.ftruncate(fd, 0)
    _ = Darwin.lseek(fd, 0, SEEK_SET)
    let pidText = "\(ProcessInfo.processInfo.processIdentifier)\n"
    _ = pidText.withCString { ptr in
        Darwin.write(fd, ptr, strlen(ptr))
    }
    return fd
}

func cleanupAndExit(
    fsWatcher: FSEventsWatcher?,
    httpsProxy: HTTPSDomainProxy?,
    autoThaw: AutoThawProxy,
    dnsServer: LocalDNSServer,
    bridge: VsockBridge,
    hostNet: HostNetSupervisor?,
    pressureGuard: MemoryPressureGuard? = nil,
    lockFD: Int32 = -1,
    code: Int32 = 0
) -> Never {
    cleanupExitLock.lock()
    pressureGuard?.stop()
    fsWatcher?.stop()
    httpsProxy?.stop()
    autoThaw.stop()
    dnsServer.stop()
    bridge.stop()
    hostNet?.stop()
    try? FileManager.default.removeItem(at: FirnPaths.pidFileURL)
    if lockFD >= 0 {
        Darwin.close(lockFD)
    }
    exit(code)
}

private func shutdownVMAndExit(state: DaemonState) -> Never {
    guard state.beginShutdown() else {
        while true {
            Thread.sleep(forTimeInterval: 1.0)
        }
    }
    state.hostServer?.stop()
    let shouldWaitForPoweroff = !state.runner.isHibernated
    if shouldWaitForPoweroff {
        // Ask guest PID 1 via firn-guestd to flush buffers, fstrim, and remount rootfs read-only.
        _ = try? state.bridge.guestHTTP(method: "POST", path: "/poweroff", timeoutSeconds: 1.5)
    }
    // Tear down host listeners and firn-hostnet immediately so ports/subprocesses are released
    // even if launchd sends SIGKILL before guest fstrim/poweroff finishes.
    state.pressureGuard?.stop()
    state.fsWatcher?.stop()
    state.httpsProxy?.stop()
    state.autoThaw.stop()
    state.dnsServer.stop()
    state.hostNet?.stop()
    if shouldWaitForPoweroff {
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
        pressureGuard: state.pressureGuard,
        lockFD: state.lockFD,
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

    let lockFD = try acquireDaemonSingletonLock()
    let cfg = FirnConfig.load()
    try String(ProcessInfo.processInfo.processIdentifier).write(to: FirnPaths.pidFileURL, atomically: true, encoding: .utf8)

    let hostNetSupervisor = HostNetSupervisor(config: cfg)
    var hostNetRunning = false
    if let hostNetSupervisor {
        do {
            try hostNetSupervisor.start()
            hostNetRunning = true
            hostNetSupervisor.pushDNSServers(VsockBridge.currentMacOSDNSServers())
        } catch {
            hostNetSupervisor.stop()
            fputs("[firnd] warning: firn-hostnet failed to start (\(error.localizedDescription)); falling back to VZ NAT\n", stderr)
            fflush(stderr)
        }
    }
    let hostNet: HostNetSupervisor? = hostNetRunning ? hostNetSupervisor : nil

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
        fsWatcher: fsWatcher,
        lockFD: lockFD
    )
    let pressureGuard = MemoryPressureGuard(
        runner: runner,
        bridge: bridge,
        balloon: balloon,
        autoThaw: autoThaw
    )
    state.pressureGuard = pressureGuard

    autoThaw.onProjectsChanged = { projects in
        httpsProxy?.reloadCertificates(projects: projects)
    }

    runner.onVMNetSocketPairReady = { fd in
        if let hostNet {
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
        balloon.convergeAfterResume()
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
            hostNet: hostNet,
            pressureGuard: pressureGuard
        ) {
            shutdownVMAndExit(state: state)
        }
        try hostServer.start()
        state.hostServer = hostServer
        pressureGuard.start()

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
            guard state.beginShutdown() else {
                return
            }
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
                pressureGuard: pressureGuard,
                lockFD: lockFD,
                code: error == nil ? 0 : 1
            )
        }

        pushGuestConfigAndProxy(bridge: bridge, cfg: cfg, proxyState: nil)

        // Forward host-initiated proxy/port/utun activity every 5s so guest reaper keeps exact idle times.
        DispatchQueue.global(qos: .utility).async {
            var lastPushedActive: [String: Int] = [:]
            while true {
                Thread.sleep(forTimeInterval: 5.0)
                if runner.isHibernated {
                    lastPushedActive = [:]
                    continue
                }
                let localAct = autoThaw.drainActivitySnapshot()
                let hnAct = hostNetRunning ? hostNet?.drainActivity() : nil
                var mergedActive = localAct.active
                if let hnAct {
                    for (k, v) in hnAct.active {
                        mergedActive[k, default: 0] += v
                    }
                }
                var touchedSet = Set(localAct.touched)
                if let hnAct {
                    for p in hnAct.touched {
                        touchedSet.insert(p)
                    }
                }
                if !touchedSet.isEmpty || mergedActive != lastPushedActive {
                    let payload: [String: Any] = [
                        "activeProjects": mergedActive,
                        "touchedProjects": Array(touchedSet),
                    ]
                    if let body = try? JSONSerialization.data(withJSONObject: payload),
                       let (code, _) = try? bridge.guestHTTP(method: "POST", path: "/activity", body: body, timeoutSeconds: 2.0),
                       code < 300 {
                        lastPushedActive = mergedActive
                    }
                }
            }
        }

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
                    let projects = (obj["projects"] as? [[String: Any]]) ?? []
                    let anyActive = projects.contains { (($0["runningCount"] as? Int) ?? 0) > 0 }
                    let k3sRunning = ((obj["capabilities"] as? [String: Any])?["k3sRunning"] as? Bool) ?? false
                    if currentCfg.autoTrimMinutes > 0 && !anyActive && !k3sRunning {
                        let trimEveryTicks = max(1, currentCfg.autoTrimMinutes * 4)
                        if tick % trimEveryTicks == 0 {
                            _ = try? bridge.guestHTTP(method: "POST", path: "/disk/trim", timeoutSeconds: 45.0)
                        }
                    }
                    if currentCfg.hibernateSeconds > 0 {
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
            pressureGuard: pressureGuard,
            lockFD: lockFD,
            code: 1
        )
    }
}

try runDaemon()
