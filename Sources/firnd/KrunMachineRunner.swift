import Darwin
import Foundation
import FirnCore

public final class KrunMachineRunner: VMBackend {
    public let config: FirnConfig
    private var proc: Process?
    private var serialHandle: FileHandle?
    private let vsockMuxURL: URL
    private let stateLock = NSLock()
    private let wakeCond = NSCondition()
    private var waking = false
    private var _hibernated = false
    private var suppressStop = false
    private var registeredListeners: [UInt32: Int32] = [:]
    private var listenerHandlers: [UInt32: (any StreamChannel) -> Void] = [:]

    public var onStop: ((Error?) -> Void)?
    public var onPrepareHibernate: (() -> Void)?
    public var onResumeFromHibernate: (() -> Void)?
    public var onVMNetSocketPairReady: ((Int32) -> Void)?

    public init(config: FirnConfig) {
        self.config = config
        self.vsockMuxURL = FirnPaths.runDir.appendingPathComponent("krunkit-vsock.sock")
    }

    public static func locateKrunkit() -> String? {
        if let override = ProcessInfo.processInfo.environment["FIRN_KRUNKIT_PATH"],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        for path in ["/opt/homebrew/bin/krunkit", "/usr/local/bin/krunkit"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let c = URL(fileURLWithPath: String(dir)).appendingPathComponent("krunkit").path
                if FileManager.default.isExecutableFile(atPath: c) {
                    return c
                }
            }
        }
        return nil
    }

    public var isHibernated: Bool {
        stateLock.lock()
        let v = _hibernated
        stateLock.unlock()
        return v
    }

    public var capabilities: VMBackendCapabilities {
        VMBackendCapabilities(
            backendName: "krun",
            nestedVirtualizationSupported: false,
            nestedVirtualizationEnabled: false,
            saveRestoreSupported: false,
            saveRestoreReason: "krunkit uses dynamic MADV_FREE reclaim and park hibernate",
            gpuAccelerationEnabled: config.gpu,
            dynamicHostReclaim: true,
            fastVirtioNet: true,
            guestPIDs: proc.map { [$0.processIdentifier] } ?? []
        )
    }

    public func start() throws {
        guard let krunkitPath = Self.locateKrunkit() else {
            throw NSError(
                domain: "FirnKrun",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "`krunkit` not found. Install via `brew tap libkrun/krun && brew install krunkit`, or use `--backend vz`."]
            )
        }
        let fm = FileManager.default
        _ = try FirnDistribution.ensureSparseDataDisk()
        for required in [FirnPaths.kernelURL, FirnPaths.initramfsURL, FirnPaths.rootfsURL, FirnPaths.dataDiskURL] {
            guard fm.fileExists(atPath: required.path) else {
                throw NSError(domain: "FirnKrun", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing VM artifact: \(required.path). Run `firn images pull` (or `make build`)."])
            }
        }
        try fm.createDirectory(at: FirnPaths.runDir, withIntermediateDirectories: true)
        unlink(vsockMuxURL.path)

        let netSockURL = FirnPaths.runDir.appendingPathComponent("krunkit-net.sock")
        unlink(netSockURL.path)

        let homePath = fm.homeDirectoryForCurrentUser.path
        let cmdline = "console=hvc0 root=/dev/vda rootfstype=ext4 rw init=/sbin/init firn.home=\(homePath) firn.fs=\(config.fsMode) firn.net=jumbo quiet"

        fm.createFile(atPath: FirnPaths.serialLogURL.path, contents: nil)
        let lh = try FileHandle(forWritingTo: FirnPaths.serialLogURL)
        try lh.truncate(atOffset: 0)
        self.serialHandle = lh

        var args: [String] = [
            "--cpus", String(config.cpus),
            "--memory", String(config.memoryGiB * 1024),
            "--bootloader", "linux,kernel=\(FirnPaths.kernelURL.path),initrd=\(FirnPaths.initramfsURL.path),cmdline=\(cmdline)",
            "--device", "virtio-blk,path=\(FirnPaths.rootfsURL.path)",
            "--device", "virtio-blk,path=\(FirnPaths.dataDiskURL.path)",
            "--device", "virtio-fs,sharedDir=\(homePath),mountTag=host-home",
            "--device", "virtio-vsock,port=1024,socketURL=\(vsockMuxURL.path)",
            "--device", "virtio-net",
        ]
        if config.gpu {
            args.append(contentsOf: ["--device", "virtio-gpu,virglrenderer=on,venus=on"])
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: krunkitPath)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = lh
        p.standardError = lh
        p.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.stateLock.lock()
            let suppressed = self.suppressStop
            self.stateLock.unlock()
            if !suppressed {
                let err = process.terminationStatus == 0 ? nil : NSError(domain: "FirnKrun", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "krunkit exited with status \(process.terminationStatus)"])
                self.onStop?(err)
            }
        }
        try p.run()
        stateLock.lock()
        self.proc = p
        self._hibernated = false
        stateLock.unlock()

        let deadline = Date().addingTimeInterval(8.0)
        while Date() < deadline {
            if fm.fileExists(atPath: vsockMuxURL.path) {
                break
            }
            if !p.isRunning {
                throw NSError(domain: "FirnKrun", code: 3, userInfo: [NSLocalizedDescriptionKey: "krunkit exited during startup"])
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    public func stopGracefully(timeoutSeconds: Double = 8.0) {
        stateLock.lock()
        let p = self.proc
        stateLock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            _ = Darwin.kill(p.processIdentifier, SIGKILL)
        }
    }

    public func hibernate() throws -> HibernateOutcome {
        let started = Date()
        let before = HostProcessMetrics.current(daemonPID: getpid())
        stateLock.lock()
        if _hibernated {
            stateLock.unlock()
            return HibernateOutcome(mode: "park", savedStateBytes: 0, durationMs: 0, hostFootprintBeforeBytes: before.footprintBytes, hostFootprintAfterBytes: before.footprintBytes)
        }
        suppressStop = true
        stateLock.unlock()
        defer {
            stateLock.lock()
            suppressStop = false
            stateLock.unlock()
        }
        onPrepareHibernate?()
        stopGracefully(timeoutSeconds: 8.0)
        stateLock.lock()
        self.proc = nil
        self._hibernated = true
        stateLock.unlock()
        Thread.sleep(forTimeInterval: 0.2)
        let after = HostProcessMetrics.current(daemonPID: getpid())
        let ms = (Date().timeIntervalSince(started) * 1000.0 * 100.0).rounded() / 100.0
        return HibernateOutcome(mode: "park", savedStateBytes: 0, durationMs: ms, hostFootprintBeforeBytes: before.footprintBytes, hostFootprintAfterBytes: after.footprintBytes)
    }

    public func ensureAwake() throws {
        wakeCond.lock()
        while waking {
            wakeCond.wait()
        }
        stateLock.lock()
        let need = _hibernated || proc == nil || !(proc?.isRunning ?? false)
        stateLock.unlock()
        if !need {
            wakeCond.unlock()
            return
        }
        waking = true
        wakeCond.unlock()
        defer {
            wakeCond.lock()
            waking = false
            wakeCond.broadcast()
            wakeCond.unlock()
        }
        try start()
        onResumeFromHibernate?()
    }

    public func registerSocketListener(port: UInt32, handler: @escaping (any StreamChannel) -> Void) {
        let listenPath = "\(vsockMuxURL.path)_\(port)"
        stateLock.lock()
        listenerHandlers[port] = handler
        if let existingFD = registeredListeners[port] {
            Darwin.close(existingFD)
            registeredListeners.removeValue(forKey: port)
        }
        stateLock.unlock()

        if let fd = try? bindUnixSocket(at: URL(fileURLWithPath: listenPath)) {
            stateLock.lock()
            registeredListeners[port] = fd
            stateLock.unlock()
            Thread.detachNewThread { [weak self] in
                while let self {
                    let cfd = Darwin.accept(fd, nil, nil)
                    if cfd < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    self.stateLock.lock()
                    let cb = self.listenerHandlers[port]
                    self.stateLock.unlock()
                    if let cb {
                        cb(UnixFDChannel(fileDescriptor: cfd))
                    } else {
                        Darwin.close(cfd)
                    }
                }
            }
        }
    }

    public func connectVsock(port: UInt32, timeoutSeconds: Double = 5.0) throws -> any StreamChannel {
        if isHibernated {
            try ensureAwake()
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(vsockMuxURL.path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw NSError(domain: "FirnKrun", code: 4, userInfo: [NSLocalizedDescriptionKey: "krunkit vsock path too long"])
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let addrLen = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + bytes.count)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addrLen) }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }
        let cmd = Data("CONNECT \(port)\n".utf8)
        guard writeAll(fd: fd, data: cmd) else {
            Darwin.close(fd)
            throw NSError(domain: "FirnKrun", code: 5, userInfo: [NSLocalizedDescriptionKey: "krunkit vsock CONNECT failed"])
        }
        var replyBuf = [UInt8](repeating: 0, count: 64)
        let n = Darwin.read(fd, &replyBuf, replyBuf.count)
        guard n > 0, let reply = String(bytes: replyBuf[0..<n], encoding: .utf8), reply.hasPrefix("OK") else {
            Darwin.close(fd)
            throw NSError(domain: "FirnKrun", code: 6, userInfo: [NSLocalizedDescriptionKey: "krunkit refused vsock port \(port)"])
        }
        return UnixFDChannel(fileDescriptor: fd)
    }

    public func getBalloonTargetBytes() -> UInt64 {
        config.maxMemoryBytes
    }

    public func setBalloonTargetBytes(_ bytes: UInt64) {}

    deinit {
        stateLock.lock()
        for fd in registeredListeners.values {
            Darwin.close(fd)
        }
        registeredListeners.removeAll()
        stateLock.unlock()
    }
}
