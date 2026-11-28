import Darwin
import Dispatch
import Foundation
import FirnCore

public final class MemoryPressureGuard {
    private let runner: any VMBackend
    private let bridge: VsockBridge
    private let balloon: BalloonController
    private let autoThaw: AutoThawProxy
    private let queue = DispatchQueue(label: "dev.firn.memory-pressure", qos: .utility)

    private var source: DispatchSourceMemoryPressure?
    private let lock = NSLock()
    private var currentLevel = "normal"
    private var lastReclaimAt: Date?
    private var lastEventAt: Date?
    private var reclaimCount = 0
    private var lastFrozenProjects: [String] = []
    private var reclaiming = false

    public init(
        runner: any VMBackend,
        bridge: VsockBridge,
        balloon: BalloonController,
        autoThaw: AutoThawProxy
    ) {
        self.runner = runner
        self.bridge = bridge
        self.balloon = balloon
        self.autoThaw = autoThaw
    }

    public func start() {
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let event = src.data
            let now = Date()
            let nextLevel: String
            if event.contains(.critical) {
                nextLevel = "critical"
            } else if event.contains(.warning) {
                nextLevel = "warning"
            } else {
                nextLevel = "normal"
            }

            self.lock.lock()
            self.currentLevel = nextLevel
            self.lastEventAt = now
            self.lock.unlock()

            if nextLevel == "warning" || nextLevel == "critical" {
                _ = self.triggerReclaim(level: nextLevel, force: false)
            }
        }
        src.resume()
        lock.lock()
        self.source = src
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let src = source
        source = nil
        lock.unlock()
        src?.cancel()
    }

    public func statusDictionary() -> [String: Any] {
        let cfg = FirnConfig.load()
        lock.lock()
        let level = currentLevel
        let count = reclaimCount
        let frozen = lastFrozenProjects
        let lastAt = lastReclaimAt
        let evtAt = lastEventAt
        lock.unlock()

        let iso = ISO8601DateFormatter()
        var out: [String: Any] = [
            "enabled": cfg.memoryPressureReclaim,
            "level": level,
            "reclaimCount": count,
            "lastFrozenProjects": frozen,
        ]
        if let lastAt {
            out["lastReclaimAt"] = iso.string(from: lastAt)
        }
        if let evtAt {
            out["lastEventAt"] = iso.string(from: evtAt)
        }
        return out
    }

    @discardableResult
    public func triggerReclaim(level: String, force: Bool = false) -> [String: Any] {
        let cfg = FirnConfig.load()
        if !force && !cfg.memoryPressureReclaim {
            return ["ok": true, "skipped": "disabled", "level": level]
        }
        if runner.isHibernated {
            return ["ok": true, "skipped": "hibernated", "level": level]
        }

        let normalized = (level.lowercased() == "critical") ? "critical" : "warning"
        let cooldownSeconds: TimeInterval = (normalized == "critical") ? 20.0 : 60.0
        let now = Date()

        lock.lock()
        if reclaiming {
            lock.unlock()
            return ["ok": true, "skipped": "in_progress", "level": normalized]
        }
        if !force, let last = lastReclaimAt, now.timeIntervalSince(last) < cooldownSeconds {
            lock.unlock()
            return ["ok": true, "skipped": "cooldown", "level": normalized]
        }
        reclaiming = true
        lock.unlock()

        defer {
            lock.lock()
            reclaiming = false
            lock.unlock()
        }

        var frozenProjects: [String] = []
        if let (code, raw) = try? bridge.guestHTTP(method: "GET", path: "/status", timeoutSeconds: 4.0),
           code == 200,
           let statusObj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let rawProjects = statusObj["projects"] as? [[String: Any]] {
            let fm = FileManager.default
            struct Candidate {
                let project: String
                let orphaned: Bool
                let idleForSeconds: Double
                let memoryBytes: UInt64
            }
            var candidates: [Candidate] = []
            for p in rawProjects {
                let name = (p["project"] as? String) ?? ""
                let hasCompose = (p["hasComposeProject"] as? Bool) ?? false
                let exempt = (p["exempt"] as? Bool) ?? false
                let runningCount = (p["runningCount"] as? Int) ?? 0
                if !hasCompose || exempt || runningCount <= 0 || name.isEmpty {
                    continue
                }
                let workingDir = (p["workingDir"] as? String) ?? ""
                let orphaned = !workingDir.isEmpty && !fm.fileExists(atPath: workingDir)
                let idle = (p["idleForSeconds"] as? NSNumber)?.doubleValue ?? 0
                let mem = (p["memoryBytes"] as? NSNumber)?.uint64Value ?? 0
                if force || orphaned || (normalized == "critical" && idle >= 10.0) || (normalized == "warning" && idle >= 30.0) {
                    candidates.append(Candidate(project: name, orphaned: orphaned, idleForSeconds: idle, memoryBytes: mem))
                }
            }

            candidates.sort { a, b in
                if a.orphaned != b.orphaned { return a.orphaned && !b.orphaned }
                if a.idleForSeconds != b.idleForSeconds { return a.idleForSeconds > b.idleForSeconds }
                return a.memoryBytes > b.memoryBytes
            }

            let limit = (normalized == "warning") ? 1 : candidates.count
            for cand in candidates.prefix(limit) {
                let encoded = cand.project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cand.project
                if let (fcode, _) = try? bridge.guestHTTP(method: "POST", path: "/freeze/\(encoded)?reclaim=1", timeoutSeconds: 15.0),
                   fcode < 300 {
                    frozenProjects.append(cand.project)
                }
            }
        }

        let balloonInfo = balloon.shrinkToGuestDemand(dropCaches: true, converge: true)
        if !frozenProjects.isEmpty {
            autoThaw.syncTopologyNow()
            fputs("[firnd] memory pressure (\(normalized)): frozen+reclaimed \(frozenProjects.joined(separator: ", "))\n", stderr)
            fflush(stderr)
        }

        lock.lock()
        reclaimCount += 1
        lastReclaimAt = Date()
        lastFrozenProjects = frozenProjects
        lock.unlock()

        return [
            "ok": true,
            "level": normalized,
            "forced": force,
            "frozenProjects": frozenProjects,
            "balloon": balloonInfo,
        ]
    }
}
