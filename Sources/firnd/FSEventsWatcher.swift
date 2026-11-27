import CoreServices
import Foundation
import FirnCore

public final class FSEventsWatcher {
    private let watchRoot: String
    private let ignorePrefix: String
    private let onBatch: ([String]) -> Void
    private let queue = DispatchQueue(label: "dev.firn.fsevents")
    private let lock = NSLock()
    private var streamRef: FSEventStreamRef?
    private var pendingRelPaths: Set<String> = []
    private var flushScheduled = false

    public init(
        watchRoot: URL = FileManager.default.homeDirectoryForCurrentUser,
        ignoreDir: URL = FirnPaths.stateDir,
        onBatch: @escaping ([String]) -> Void
    ) {
        self.watchRoot = watchRoot.standardizedFileURL.path
        self.ignorePrefix = ignoreDir.standardizedFileURL.path
        self.onBatch = onBatch
    }

    public func start() {
        var ctx = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info, numEvents > 0 else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            var collected: [String] = []
            collected.reserveCapacity(numEvents)
            for item in paths {
                if let p = item as? String {
                    collected.append(p)
                }
            }
            watcher.enqueue(paths: collected)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &ctx,
            [watchRoot] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.005,
            flags
        ) else {
            return
        }
        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
    }

    private func isIgnoredRuntimePath(_ p: String) -> Bool {
        if p == ignorePrefix {
            return true
        }
        let stateSlash = ignorePrefix + "/"
        guard p.hasPrefix(stateSlash) else {
            return false
        }
        let rel = String(p.dropFirst(stateSlash.count))
        for dir in ["images", "run", "certs"] {
            if rel == dir || rel.hasPrefix(dir + "/") {
                return true
            }
        }
        if rel == "data.ext4" || rel == "machine-id.bin" || rel.hasPrefix("vm-state.vzvmsave") {
            return true
        }
        if !rel.contains("/") && rel.hasSuffix(".log") {
            return true
        }
        return false
    }

    private func enqueue(paths: [String]) {
        let rootSlash = watchRoot.hasSuffix("/") ? watchRoot : watchRoot + "/"
        var rels: [String] = []
        rels.reserveCapacity(paths.count)
        for p in paths {
            if isIgnoredRuntimePath(p) {
                continue
            }
            if p == watchRoot {
                rels.append("")
            } else if p.hasPrefix(rootSlash) {
                rels.append(String(p.dropFirst(rootSlash.count)))
            }
        }
        guard !rels.isEmpty else { return }

        lock.lock()
        for r in rels {
            pendingRelPaths.insert(r)
        }
        let shouldSchedule = !flushScheduled
        if shouldSchedule {
            flushScheduled = true
        }
        lock.unlock()

        if shouldSchedule {
            queue.asyncAfter(deadline: .now() + 0.008) { [weak self] in
                self?.flush()
            }
        }
    }

    private func flush() {
        lock.lock()
        let batch = Array(pendingRelPaths)
        pendingRelPaths.removeAll()
        flushScheduled = false
        lock.unlock()
        if !batch.isEmpty {
            onBatch(batch)
        }
    }

    deinit {
        stop()
    }
}
