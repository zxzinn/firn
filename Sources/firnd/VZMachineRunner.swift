import Darwin
import Foundation
import FirnCore
import Virtualization

public final class VZMachineRunner: NSObject, VZVirtualMachineDelegate, VMBackend {
    public let config: FirnConfig
    public let vmQueue = DispatchQueue(label: "dev.firn.vz-queue")
    private var vm: VZVirtualMachine?
    private var socketDevice: VZVirtioSocketDevice?
    private var balloonDevice: VZVirtioTraditionalMemoryBalloonDevice?
    private var listeners: [UInt32: VZVirtioSocketListener] = [:]
    private var registeredHandlers: [UInt32: (any StreamChannel) -> Void] = [:]
    private var delegates: [SocketListenerBox] = []
    private var serialHandle: FileHandle?
    private var vmnetPeerHandle: FileHandle?
    private var useFastNet = false

    private let stateLock = NSLock()
    private let wakeCond = NSCondition()
    private var waking = false
    private var _hibernated = false
    private var _hibernating = false
    private var suppressStopCallback = false
    private var stopWaitSem: DispatchSemaphore?
    private var _capabilities: VMBackendCapabilities

    public var onStop: ((Error?) -> Void)?
    public var onPrepareHibernate: (() -> Void)?
    public var onResumeFromHibernate: (() -> Void)?
    public var onVMNetSocketPairReady: ((Int32) -> Void)?

    public init(config: FirnConfig, useFastNet: Bool = true) {
        self.config = config
        self.useFastNet = useFastNet
        var nestedSupported = false
        var nestedEnabled = false
        if #available(macOS 15.0, *) {
            nestedSupported = VZGenericPlatformConfiguration.isNestedVirtualizationSupported
            nestedEnabled = nestedSupported && config.nestedVirtualization
        }
        self._capabilities = VMBackendCapabilities(
            backendName: "vz",
            nestedVirtualizationSupported: nestedSupported,
            nestedVirtualizationEnabled: nestedEnabled,
            saveRestoreSupported: false,
            saveRestoreReason: "uninitialized",
            gpuAccelerationEnabled: false,
            dynamicHostReclaim: false,
            fastVirtioNet: useFastNet,
            guestPIDs: []
        )
    }

    public var isHibernated: Bool {
        stateLock.lock()
        let v = _hibernated || _hibernating
        stateLock.unlock()
        return v
    }

    public var capabilities: VMBackendCapabilities {
        stateLock.lock()
        let v = _capabilities
        stateLock.unlock()
        return v
    }

    private func loadOrCreateMachineIdentifier() throws -> VZGenericMachineIdentifier {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: FirnPaths.machineIdURL),
           let id = VZGenericMachineIdentifier(dataRepresentation: data) {
            return id
        }
        let fresh = VZGenericMachineIdentifier()
        try fm.createDirectory(at: FirnPaths.stateDir, withIntermediateDirectories: true)
        try fresh.dataRepresentation.write(to: FirnPaths.machineIdURL, options: .atomic)
        return fresh
    }

    private static func tuneDgramPairFD(_ fd: Int32) {
        let attempts: [(Int32, Int32)] = [
            (4_194_304, 4_194_304),
            (4_194_304, 2_097_152),
            (4_194_304, 1_048_576),
            (2_097_152, 1_048_576),
        ]
        for (rcv, snd) in attempts {
            var r = rcv
            var s = snd
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &r, socklen_t(MemoryLayout<Int32>.size))
            if setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &s, socklen_t(MemoryLayout<Int32>.size)) == 0 {
                break
            }
        }
    }

    private static func encodeMountKernelParam(_ guestPath: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/._-")
        return guestPath.addingPercentEncoding(withAllowedCharacters: allowed) ?? guestPath
    }

    private func buildConfiguration(truncateSerial: Bool) throws -> (vzConfig: VZVirtualMachineConfiguration, hostSocketpairFD: Int32?) {
        let fm = FileManager.default
        _ = try FirnDistribution.ensureSparseDataDisk()
        for required in [FirnPaths.kernelURL, FirnPaths.initramfsURL, FirnPaths.rootfsURL, FirnPaths.dataDiskURL] {
            guard fm.fileExists(atPath: required.path) else {
                throw NSError(domain: "Firn", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing VM artifact: \(required.path). Run `firn images pull` (or `make build`)."])
            }
        }
        try fm.createDirectory(at: FirnPaths.runDir, withIntermediateDirectories: true)

        let vzConfig = VZVirtualMachineConfiguration()
        vzConfig.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, min(config.cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        vzConfig.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, min(config.maxMemoryBytes, VZVirtualMachineConfiguration.maximumAllowedMemorySize))

        let homePath = fm.homeDirectoryForCurrentUser.path
        var activeExtraMounts: [(idx: Int, hostPath: String, guestPath: String, readOnly: Bool)] = []
        for (idx, mount) in config.extraMounts.enumerated() {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: mount.hostPath, isDirectory: &isDir), isDir.boolValue {
                let targetGuest = mount.guestPath.isEmpty ? mount.hostPath : mount.guestPath
                activeExtraMounts.append((idx: idx, hostPath: mount.hostPath, guestPath: targetGuest, readOnly: mount.readOnly))
            }
        }
        let netMode = (useFastNet && onVMNetSocketPairReady != nil) ? "jumbo" : "nat"
        let bootLoader = VZLinuxBootLoader(kernelURL: FirnPaths.kernelURL)
        bootLoader.initialRamdiskURL = FirnPaths.initramfsURL
        var cmdLine = "console=hvc0 root=/dev/vda rootfstype=ext4 rw init=/sbin/init firn.home=\(homePath) firn.fs=\(config.fsMode) firn.net=\(netMode) firn.disksync=\(config.diskSyncMode)"
        if !activeExtraMounts.isEmpty {
            let encodedSpecs = activeExtraMounts.map { item in
                "\(item.idx):\(Self.encodeMountKernelParam(item.guestPath)):\(item.readOnly ? "ro" : "rw")"
            }.joined(separator: ",")
            cmdLine += " firn.mounts=\(encodedSpecs)"
        }
        bootLoader.commandLine = "\(cmdLine) quiet"
        vzConfig.bootLoader = bootLoader

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try loadOrCreateMachineIdentifier()
        var nestedSupported = false
        var nestedEnabled = false
        if #available(macOS 15.0, *) {
            nestedSupported = VZGenericPlatformConfiguration.isNestedVirtualizationSupported
            if nestedSupported && config.nestedVirtualization {
                platform.isNestedVirtualizationEnabled = true
                nestedEnabled = true
            }
        }
        vzConfig.platform = platform

        // Serial console -> ~/.firn/serial.log
        if !fm.fileExists(atPath: FirnPaths.serialLogURL.path) {
            fm.createFile(atPath: FirnPaths.serialLogURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: FirnPaths.serialLogURL)
        if truncateSerial {
            try logHandle.truncate(atOffset: 0)
        } else {
            _ = try? logHandle.seekToEnd()
        }
        self.serialHandle = logHandle
        let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialConfig.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: logHandle)
        vzConfig.serialPorts = [serialConfig]

        // Block devices: cached APFS I/O on rootfs (/dev/vda) and persistent data/swap (/dev/vdb)
        let syncMode: VZDiskImageSynchronizationMode = config.diskSyncMode == "fsync" ? .fsync : .none
        let rootAttach = try VZDiskImageStorageDeviceAttachment(url: FirnPaths.rootfsURL, readOnly: false, cachingMode: .cached, synchronizationMode: syncMode)
        let dataAttach = try VZDiskImageStorageDeviceAttachment(url: FirnPaths.dataDiskURL, readOnly: false, cachingMode: .cached, synchronizationMode: syncMode)
        vzConfig.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: rootAttach),
            VZVirtioBlockDeviceConfiguration(attachment: dataAttach),
        ]

        // Networking: connected jumbo socketpair (16384 MTU) via firn-hostnet when available, else VZ NAT.
        var hostSideFD: Int32?
        let netConfig = VZVirtioNetworkDeviceConfiguration()
        if netMode == "jumbo" {
            var sv: [Int32] = [-1, -1]
            guard Darwin.socketpair(AF_UNIX, SOCK_DGRAM, 0, &sv) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            Self.tuneDgramPairFD(sv[0])
            Self.tuneDgramPairFD(sv[1])
            let vzHandle = FileHandle(fileDescriptor: sv[1], closeOnDealloc: true)
            self.vmnetPeerHandle = vzHandle
            let fhAttach = VZFileHandleNetworkDeviceAttachment(fileHandle: vzHandle)
            if #available(macOS 13.0, *) {
                fhAttach.maximumTransmissionUnit = 16384
            }
            netConfig.attachment = fhAttach
            if let guestMAC = VZMACAddress(string: "52:54:00:12:34:02") {
                netConfig.macAddress = guestMAC
            }
            hostSideFD = sv[0]
        } else {
            netConfig.attachment = VZNATNetworkDeviceAttachment()
        }
        vzConfig.networkDevices = [netConfig]

        // Entropy, memory balloon, virtio-vsock
        vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vzConfig.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vzConfig.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // VirtioFS shares: host home + optional Rosetta
        var fsDevices: [VZDirectorySharingDeviceConfiguration] = []
        let homeDir = VZSharedDirectory(url: URL(fileURLWithPath: homePath), readOnly: false)
        let homeShare = VZVirtioFileSystemDeviceConfiguration(tag: "host-home")
        homeShare.share = VZSingleDirectoryShare(directory: homeDir)
        fsDevices.append(homeShare)

        #if arch(arm64)
        if #available(macOS 13.0, *), VZLinuxRosettaDirectoryShare.availability == .installed {
            if let rosettaShare = try? VZLinuxRosettaDirectoryShare() {
                let rosettaCfg = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                rosettaCfg.share = rosettaShare
                fsDevices.append(rosettaCfg)
            }
        }
        #endif
        for item in activeExtraMounts {
            let shared = VZSharedDirectory(url: URL(fileURLWithPath: item.hostPath), readOnly: item.readOnly)
            let mountCfg = VZVirtioFileSystemDeviceConfiguration(tag: "firn-mount-\(item.idx)")
            mountCfg.share = VZSingleDirectoryShare(directory: shared)
            fsDevices.append(mountCfg)
        }
        vzConfig.directorySharingDevices = fsDevices

        try vzConfig.validate()

        var srSupported = false
        var srReason = "unsupported on this macOS version"
        #if arch(arm64)
        do {
            try vzConfig.validateSaveRestoreSupport()
            srSupported = true
            srReason = "supported"
        } catch {
            srSupported = false
            srReason = error.localizedDescription
        }
        #endif

        stateLock.lock()
        _capabilities = VMBackendCapabilities(
            backendName: "vz",
            nestedVirtualizationSupported: nestedSupported,
            nestedVirtualizationEnabled: nestedEnabled,
            saveRestoreSupported: srSupported,
            saveRestoreReason: srReason,
            gpuAccelerationEnabled: false,
            dynamicHostReclaim: false,
            fastVirtioNet: netMode == "jumbo",
            guestPIDs: []
        )
        stateLock.unlock()

        return (vzConfig, hostSideFD)
    }

    public func start() throws {
        guard VZVirtualMachine.isSupported else {
            throw NSError(domain: "Firn", code: 1, userInfo: [NSLocalizedDescriptionKey: "Virtualization.framework is not supported on this Mac"])
        }
        try startFresh(truncateSerial: true)
    }

    private func startFresh(truncateSerial: Bool) throws {
        try? FileManager.default.removeItem(at: FirnPaths.vmStateURL)
        let (vzConfig, hostSideFD) = try buildConfiguration(truncateSerial: truncateSerial)
        if let hostSideFD {
            onVMNetSocketPairReady?(hostSideFD)
        }

        let machine: VZVirtualMachine = vmQueue.sync {
            let m = VZVirtualMachine(configuration: vzConfig, queue: vmQueue)
            m.delegate = self
            self.vm = m
            self.socketDevice = m.socketDevices.first as? VZVirtioSocketDevice
            self.balloonDevice = m.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice
            self.reinstallListenersLocked()
            return m
        }

        let sem = DispatchSemaphore(value: 0)
        var capturedError: Error?
        vmQueue.async {
            machine.start { result in
                if case .failure(let err) = result {
                    capturedError = err
                }
                sem.signal()
            }
        }
        sem.wait()
        if let capturedError {
            throw capturedError
        }
        stateLock.lock()
        _hibernated = false
        stateLock.unlock()
    }

    private func reinstallListenersLocked() {
        guard let sockDev = self.socketDevice else { return }
        self.listeners.removeAll()
        self.delegates.removeAll()
        for (port, handler) in registeredHandlers {
            let box = SocketListenerBox(handler: handler)
            let listener = VZVirtioSocketListener()
            listener.delegate = box
            self.delegates.append(box)
            self.listeners[port] = listener
            sockDev.setSocketListener(listener, forPort: port)
        }
    }

    public func hibernate() throws -> HibernateOutcome {
        let started = Date()
        let beforeHost = HostProcessMetrics.current(daemonPID: getpid())

        stateLock.lock()
        if _hibernated || _hibernating {
            stateLock.unlock()
            return HibernateOutcome(
                mode: FileManager.default.fileExists(atPath: FirnPaths.vmStateURL.path) ? "snapshot" : "park",
                savedStateBytes: (try? FirnPaths.vmStateURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0,
                durationMs: 0,
                hostFootprintBeforeBytes: beforeHost.footprintBytes,
                hostFootprintAfterBytes: beforeHost.footprintBytes
            )
        }
        _hibernating = true
        let useSnapshot = _capabilities.saveRestoreSupported
        stateLock.unlock()

        var mode = "park"
        var savedBytes: UInt64 = 0

        stateLock.lock()
        suppressStopCallback = true
        stateLock.unlock()

        defer {
            wakeCond.lock()
            stateLock.lock()
            _hibernating = false
            suppressStopCallback = false
            stateLock.unlock()
            wakeCond.broadcast()
            wakeCond.unlock()
        }

        if useSnapshot {
            let sem = DispatchSemaphore(value: 0)
            var snapErr: Error?
            vmQueue.async { [weak self] in
                guard let self, let vm = self.vm else {
                    sem.signal()
                    return
                }
                vm.pause { pauseRes in
                    if case .failure(let err) = pauseRes {
                        snapErr = err
                        sem.signal()
                        return
                    }
                    try? FileManager.default.removeItem(at: FirnPaths.vmStateURL)
                    vm.saveMachineStateTo(url: FirnPaths.vmStateURL) { saveErr in
                        if let saveErr {
                            snapErr = saveErr
                            vm.resume { _ in sem.signal() }
                            return
                        }
                        if vm.canStop {
                            vm.stop { _ in sem.signal() }
                        } else {
                            sem.signal()
                        }
                    }
                }
            }
            _ = sem.wait(timeout: .now() + 30.0)
            if snapErr == nil && FileManager.default.fileExists(atPath: FirnPaths.vmStateURL.path) {
                mode = "snapshot"
                let stats = FirnHostClient.hostSparseFileStats(at: FirnPaths.vmStateURL)
                savedBytes = stats.allocatedBytes > 0 ? stats.allocatedBytes : stats.logicalBytes
            } else {
                try? FileManager.default.removeItem(at: FirnPaths.vmStateURL)
                onPrepareHibernate?()
                stopGracefully(timeoutSeconds: 8.0)
            }
        } else {
            onPrepareHibernate?()
            stopGracefully(timeoutSeconds: 8.0)
        }

        vmQueue.sync {
            self.listeners.removeAll()
            self.delegates.removeAll()
            self.socketDevice = nil
            self.balloonDevice = nil
            self.vm = nil
            try? self.serialHandle?.close()
            self.serialHandle = nil
            try? self.vmnetPeerHandle?.close()
            self.vmnetPeerHandle = nil
        }

        stateLock.lock()
        _hibernated = true
        stateLock.unlock()

        var afterHost = HostProcessMetrics.current(daemonPID: getpid())
        for _ in 0..<15 {
            if afterHost.vmFootprintBytes == 0 {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
            afterHost = HostProcessMetrics.current(daemonPID: getpid())
        }
        let ms = (Date().timeIntervalSince(started) * 1000.0 * 100.0).rounded() / 100.0
        return HibernateOutcome(
            mode: mode,
            savedStateBytes: savedBytes,
            durationMs: ms,
            hostFootprintBeforeBytes: beforeHost.footprintBytes,
            hostFootprintAfterBytes: afterHost.footprintBytes
        )
    }

    public func ensureAwake() throws {
        wakeCond.lock()
        while waking || _hibernating {
            wakeCond.wait()
        }
        stateLock.lock()
        let needWake = _hibernated || vm == nil
        stateLock.unlock()
        if !needWake {
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

        var restored = false
        if FileManager.default.fileExists(atPath: FirnPaths.vmStateURL.path) {
            do {
                let (vzConfig, hostSideFD) = try buildConfiguration(truncateSerial: false)
                if let hostSideFD {
                    onVMNetSocketPairReady?(hostSideFD)
                }
                let machine: VZVirtualMachine = vmQueue.sync {
                    let m = VZVirtualMachine(configuration: vzConfig, queue: vmQueue)
                    m.delegate = self
                    self.vm = m
                    self.socketDevice = m.socketDevices.first as? VZVirtioSocketDevice
                    self.balloonDevice = m.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice
                    self.reinstallListenersLocked()
                    return m
                }
                let sem = DispatchSemaphore(value: 0)
                var restoreErr: Error?
                vmQueue.async {
                    machine.restoreMachineStateFrom(url: FirnPaths.vmStateURL) { err in
                        if let err {
                            restoreErr = err
                            sem.signal()
                            return
                        }
                        machine.resume { rres in
                            if case .failure(let err) = rres {
                                restoreErr = err
                            }
                            sem.signal()
                        }
                    }
                }
                sem.wait()
                if restoreErr == nil {
                    restored = true
                    try? FileManager.default.removeItem(at: FirnPaths.vmStateURL)
                    stateLock.lock()
                    _hibernated = false
                    stateLock.unlock()
                    onResumeFromHibernate?()
                } else {
                    try? FileManager.default.removeItem(at: FirnPaths.vmStateURL)
                    vmQueue.sync {
                        self.vm = nil
                        self.socketDevice = nil
                        self.balloonDevice = nil
                        try? self.vmnetPeerHandle?.close()
                        self.vmnetPeerHandle = nil
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: FirnPaths.vmStateURL)
            }
        }

        if !restored {
            try startFresh(truncateSerial: false)
            onResumeFromHibernate?()
        }
    }

    public func stopGracefully(timeoutSeconds: Double = 8.0) {
        let sem = DispatchSemaphore(value: 0)
        vmQueue.async { [weak self] in
            guard let self, let vm = self.vm else {
                sem.signal()
                return
            }
            if vm.state == .stopped {
                sem.signal()
                return
            }
            self.stateLock.lock()
            self.stopWaitSem = sem
            self.stateLock.unlock()
            if vm.canRequestStop {
                _ = try? vm.requestStop()
            }
        }
        if sem.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            let stopSem = DispatchSemaphore(value: 0)
            vmQueue.async { [weak self] in
                if self?.vm?.canStop == true {
                    self?.vm?.stop { _ in stopSem.signal() }
                } else {
                    stopSem.signal()
                }
            }
            _ = stopSem.wait(timeout: .now() + 2.0)
        }
        stateLock.lock()
        stopWaitSem = nil
        stateLock.unlock()
    }

    public func registerSocketListener(port: UInt32, handler: @escaping (any StreamChannel) -> Void) {
        vmQueue.sync {
            self.registeredHandlers[port] = handler
            guard let sockDev = self.socketDevice else { return }
            let box = SocketListenerBox(handler: handler)
            let listener = VZVirtioSocketListener()
            listener.delegate = box
            self.delegates.append(box)
            self.listeners[port] = listener
            sockDev.setSocketListener(listener, forPort: port)
        }
    }

    public func connectVsock(port: UInt32, timeoutSeconds: Double = 5.0) throws -> any StreamChannel {
        if isHibernated {
            try ensureAwake()
        }
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<VZVirtioSocketConnection, Error>?
        vmQueue.async { [weak self] in
            guard let sockDev = self?.socketDevice else {
                outcome = .failure(NSError(domain: "Firn", code: 3, userInfo: [NSLocalizedDescriptionKey: "virtio socket device unavailable"]))
                sem.signal()
                return
            }
            sockDev.connect(toPort: port) { result in
                outcome = result
                sem.signal()
            }
        }
        if sem.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            throw NSError(domain: "Firn", code: 4, userInfo: [NSLocalizedDescriptionKey: "vsock connect timeout on port \(port)"])
        }
        switch outcome {
        case .success(let conn):
            return conn
        case .failure(let err):
            throw err
        case .none:
            throw NSError(domain: "Firn", code: 5, userInfo: [NSLocalizedDescriptionKey: "vsock connect cancelled"])
        }
    }

    public func getBalloonTargetBytes() -> UInt64 {
        vmQueue.sync {
            balloonDevice?.targetVirtualMachineMemorySize ?? config.maxMemoryBytes
        }
    }

    public func setBalloonTargetBytes(_ bytes: UInt64) {
        let clamped = max(config.minBalloonBytes, min(config.maxMemoryBytes, bytes))
        vmQueue.async { [weak self] in
            self?.balloonDevice?.targetVirtualMachineMemorySize = clamped
        }
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        stateLock.lock()
        let suppressed = suppressStopCallback
        let sem = stopWaitSem
        stopWaitSem = nil
        stateLock.unlock()
        sem?.signal()
        if !suppressed {
            onStop?(nil)
        }
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        stateLock.lock()
        let suppressed = suppressStopCallback
        let sem = stopWaitSem
        stopWaitSem = nil
        stateLock.unlock()
        sem?.signal()
        if !suppressed {
            onStop?(error)
        }
    }
}

private final class SocketListenerBox: NSObject, VZVirtioSocketListenerDelegate {
    let handler: (any StreamChannel) -> Void

    init(handler: @escaping (any StreamChannel) -> Void) {
        self.handler = handler
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        handler(connection)
        return true
    }
}
