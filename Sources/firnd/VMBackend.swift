import Darwin
import Foundation
import FirnCore
import Virtualization

public protocol StreamChannel: AnyObject {
    var fileDescriptor: Int32 { get }
    func close()
}

extension VZVirtioSocketConnection: StreamChannel {}

public final class UnixFDChannel: StreamChannel {
    private let lock = NSLock()
    private var fd: Int32
    private var closed = false

    public init(fileDescriptor: Int32) {
        self.fd = fileDescriptor
    }

    public var fileDescriptor: Int32 {
        lock.lock()
        let val = fd
        lock.unlock()
        return val
    }

    public func close() {
        lock.lock()
        let shouldClose = !closed && fd >= 0
        let target = fd
        closed = true
        fd = -1
        lock.unlock()
        if shouldClose {
            Darwin.close(target)
        }
    }

    deinit {
        close()
    }
}

public struct VMBackendCapabilities: Sendable {
    public var backendName: String
    public var nestedVirtualizationSupported: Bool
    public var nestedVirtualizationEnabled: Bool
    public var saveRestoreSupported: Bool
    public var saveRestoreReason: String
    public var gpuAccelerationEnabled: Bool
    public var dynamicHostReclaim: Bool
    public var fastVirtioNet: Bool
    public var guestPIDs: [Int32]

    public func asJSONDictionary() -> [String: Any] {
        [
            "backend": backendName,
            "nestedVirtualizationSupported": nestedVirtualizationSupported,
            "nestedVirtualizationEnabled": nestedVirtualizationEnabled,
            "saveRestoreSupported": saveRestoreSupported,
            "saveRestoreReason": saveRestoreReason,
            "gpuAccelerationEnabled": gpuAccelerationEnabled,
            "dynamicHostReclaim": dynamicHostReclaim,
            "fastVirtioNet": fastVirtioNet,
        ]
    }
}

public struct HibernateOutcome: Sendable {
    public var mode: String
    public var savedStateBytes: UInt64
    public var durationMs: Double
    public var hostFootprintBeforeBytes: UInt64
    public var hostFootprintAfterBytes: UInt64

    public func asJSONDictionary() -> [String: Any] {
        [
            "mode": mode,
            "savedStateBytes": savedStateBytes,
            "durationMs": durationMs,
            "hostFootprintBeforeBytes": hostFootprintBeforeBytes,
            "hostFootprintAfterBytes": hostFootprintAfterBytes,
        ]
    }
}

public protocol VMBackend: AnyObject {
    var config: FirnConfig { get }
    var capabilities: VMBackendCapabilities { get }
    var isHibernated: Bool { get }
    var onStop: ((Error?) -> Void)? { get set }
    var onPrepareHibernate: (() -> Void)? { get set }
    var onResumeFromHibernate: (() -> Void)? { get set }
    var onVMNetSocketPairReady: ((Int32) -> Void)? { get set }

    func start() throws
    func stopGracefully(timeoutSeconds: Double)
    func hibernate() throws -> HibernateOutcome
    func ensureAwake() throws
    func registerSocketListener(port: UInt32, handler: @escaping (any StreamChannel) -> Void)
    func connectVsock(port: UInt32, timeoutSeconds: Double) throws -> any StreamChannel
    func getBalloonTargetBytes() -> UInt64
    func setBalloonTargetBytes(_ bytes: UInt64)
}
