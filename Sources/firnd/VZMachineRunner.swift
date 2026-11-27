import Darwin
import Foundation
import FirnCore
import Virtualization

public final class VZMachineRunner: NSObject, VZVirtualMachineDelegate {
    public let config: FirnConfig
    public let vmQueue = DispatchQueue(label: "dev.firn.vz-queue")
    private var vm: VZVirtualMachine?
    private var socketDevice: VZVirtioSocketDevice?
    private var balloonDevice: VZVirtioTraditionalMemoryBalloonDevice?
    private var listeners: [UInt32: VZVirtioSocketListener] = [:]
    private var delegates: [SocketListenerBox] = []
    private var serialHandle: FileHandle?
    public var onStop: ((Error?) -> Void)?

    public init(config: FirnConfig) {
        self.config = config
    }

    public func start() throws {
        guard VZVirtualMachine.isSupported else {
            throw NSError(domain: "Firn", code: 1, userInfo: [NSLocalizedDescriptionKey: "Virtualization.framework is not supported on this Mac"])
        }
        let fm = FileManager.default
        for required in [FirnPaths.kernelURL, FirnPaths.initramfsURL, FirnPaths.rootfsURL, FirnPaths.dataDiskURL] {
            guard fm.fileExists(atPath: required.path) else {
                throw NSError(domain: "Firn", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing VM artifact: \(required.path). Run `make build` first."])
            }
        }
        try fm.createDirectory(at: FirnPaths.runDir, withIntermediateDirectories: true)

        let vzConfig = VZVirtualMachineConfiguration()
        vzConfig.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, min(config.cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        vzConfig.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, min(config.maxMemoryBytes, VZVirtualMachineConfiguration.maximumAllowedMemorySize))

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let bootLoader = VZLinuxBootLoader(kernelURL: FirnPaths.kernelURL)
        bootLoader.initialRamdiskURL = FirnPaths.initramfsURL
        bootLoader.commandLine = "console=hvc0 root=/dev/vda rootfstype=ext4 rw init=/sbin/init firn.home=\(homePath) quiet"
        vzConfig.bootLoader = bootLoader
        vzConfig.platform = VZGenericPlatformConfiguration()

        // Serial console -> ~/.firn/serial.log
        fm.createFile(atPath: FirnPaths.serialLogURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: FirnPaths.serialLogURL)
        try logHandle.truncate(atOffset: 0)
        self.serialHandle = logHandle
        let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialConfig.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: logHandle)
        vzConfig.serialPorts = [serialConfig]

        // Block devices: cached APFS I/O on rootfs (/dev/vda) and persistent data/swap (/dev/vdb)
        let rootAttach = try VZDiskImageStorageDeviceAttachment(url: FirnPaths.rootfsURL, readOnly: false, cachingMode: .cached, synchronizationMode: .fsync)
        let dataAttach = try VZDiskImageStorageDeviceAttachment(url: FirnPaths.dataDiskURL, readOnly: false, cachingMode: .cached, synchronizationMode: .fsync)
        vzConfig.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: rootAttach),
            VZVirtioBlockDeviceConfiguration(attachment: dataAttach),
        ]

        // VZ NAT networking (no vmnet shared-network limit)
        let netConfig = VZVirtioNetworkDeviceConfiguration()
        netConfig.attachment = VZNATNetworkDeviceAttachment()
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
        vzConfig.directorySharingDevices = fsDevices

        try vzConfig.validate()

        let machine: VZVirtualMachine = vmQueue.sync {
            let m = VZVirtualMachine(configuration: vzConfig, queue: vmQueue)
            m.delegate = self
            self.vm = m
            self.socketDevice = m.socketDevices.first as? VZVirtioSocketDevice
            self.balloonDevice = m.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice
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
    }

    public func stopGracefully(timeoutSeconds: Double = 8.0) {
        let sem = DispatchSemaphore(value: 0)
        vmQueue.async { [weak self] in
            guard let self, let vm = self.vm else {
                sem.signal()
                return
            }
            if vm.canRequestStop {
                _ = try? vm.requestStop()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                self?.vmQueue.async {
                    if self?.vm?.canStop == true {
                        self?.vm?.stop { _ in sem.signal() }
                    } else {
                        sem.signal()
                    }
                }
            }
        }
        _ = sem.wait(timeout: .now() + timeoutSeconds + 2.0)
    }

    public func registerSocketListener(port: UInt32, handler: @escaping (VZVirtioSocketConnection) -> Void) {
        vmQueue.sync {
            guard let sockDev = self.socketDevice else { return }
            let box = SocketListenerBox(handler: handler)
            let listener = VZVirtioSocketListener()
            listener.delegate = box
            self.delegates.append(box)
            self.listeners[port] = listener
            sockDev.setSocketListener(listener, forPort: port)
        }
    }

    public func connectVsock(port: UInt32, timeoutSeconds: Double = 5.0) throws -> VZVirtioSocketConnection {
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
        onStop?(nil)
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        onStop?(error)
    }
}

private final class SocketListenerBox: NSObject, VZVirtioSocketListenerDelegate {
    let handler: (VZVirtioSocketConnection) -> Void

    init(handler: @escaping (VZVirtioSocketConnection) -> Void) {
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
