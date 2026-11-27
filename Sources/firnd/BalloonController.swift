import Darwin
import Foundation
import FirnCore

public final class BalloonController {
    private let runner: any VMBackend
    private let bridge: VsockBridge
    private let minDeltaBytes: UInt64 = 64 * 1024 * 1024

    public init(runner: any VMBackend, bridge: VsockBridge) {
        self.runner = runner
        self.bridge = bridge
    }

    public func ensureFullCapacityForThaw() {
        runner.setBalloonTargetBytes(runner.config.maxMemoryBytes)
    }

    @discardableResult
    public func shrinkToGuestDemand(dropCaches: Bool = true, converge: Bool = true) -> [String: UInt64] {
        let hostBefore = HostProcessMetrics.current(daemonPID: getpid())
        let beforeTarget = runner.getBalloonTargetBytes()
        if dropCaches {
            _ = try? bridge.guestHTTP(method: "POST", path: "/drop-caches")
        }
        let used = queryGuestUsedBytes()
        let desired = computeBalloonTargetBytes(
            usedGuestBytes: used,
            minBalloonBytes: runner.config.minBalloonBytes,
            maxMemoryBytes: runner.config.maxMemoryBytes
        )
        let delta = beforeTarget >= desired ? (beforeTarget - desired) : (desired - beforeTarget)
        var appliedTarget = beforeTarget
        if delta >= minDeltaBytes {
            runner.setBalloonTargetBytes(desired)
            appliedTarget = desired
        }
        if converge {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let updatedUsed = self.queryGuestUsedBytes()
                let updatedDesired = computeBalloonTargetBytes(
                    usedGuestBytes: updatedUsed,
                    minBalloonBytes: self.runner.config.minBalloonBytes,
                    maxMemoryBytes: self.runner.config.maxMemoryBytes
                )
                let curTarget = self.runner.getBalloonTargetBytes()
                let gap = curTarget >= updatedDesired ? (curTarget - updatedDesired) : (updatedDesired - curTarget)
                if gap >= self.minDeltaBytes {
                    self.runner.setBalloonTargetBytes(updatedDesired)
                }
            }
        }
        let hostAfter = HostProcessMetrics.current(daemonPID: getpid())
        return [
            "beforeTargetBytes": beforeTarget,
            "afterTargetBytes": appliedTarget,
            "guestUsedBytes": used,
            "hostFootprintBeforeBytes": hostBefore.footprintBytes,
            "hostFootprintAfterBytes": hostAfter.footprintBytes,
        ]
    }

    public func periodicIdleTrimIfHelpful() {
        if runner.isHibernated { return }
        let used = queryGuestUsedBytes()
        let desired = computeBalloonTargetBytes(
            usedGuestBytes: used,
            minBalloonBytes: runner.config.minBalloonBytes,
            maxMemoryBytes: runner.config.maxMemoryBytes
        )
        let curTarget = runner.getBalloonTargetBytes()
        if curTarget > desired + 256 * 1024 * 1024 {
            runner.setBalloonTargetBytes(desired)
        }
    }

    private func queryGuestUsedBytes() -> UInt64 {
        var total: UInt64 = 0
        var available: UInt64 = 0
        if let (_, data) = try? bridge.guestHTTP(method: "GET", path: "/status", timeoutSeconds: 3.0),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let vmMem = obj["vmMemory"] as? [String: Any] {
            total = (vmMem["totalBytes"] as? NSNumber)?.uint64Value ?? 0
            available = (vmMem["availableBytes"] as? NSNumber)?.uint64Value ?? 0
        }
        return total > available ? (total - available) : runner.config.minBalloonBytes
    }

    public func resetBalloon() -> [String: UInt64] {
        let beforeTarget = runner.getBalloonTargetBytes()
        runner.setBalloonTargetBytes(runner.config.maxMemoryBytes)
        return [
            "beforeTargetBytes": beforeTarget,
            "afterTargetBytes": runner.config.maxMemoryBytes,
        ]
    }
}
