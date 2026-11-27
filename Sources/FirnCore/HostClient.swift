import CommonCrypto
import Darwin
import Foundation
import Metal

public struct HostProcessMetrics: Codable, Sendable, Equatable {
    public var footprintBytes: UInt64
    public var rssBytes: UInt64
    public var daemonFootprintBytes: UInt64
    public var vmFootprintBytes: UInt64
    public var cpuPercent: Double

    public init(
        footprintBytes: UInt64 = 0,
        rssBytes: UInt64 = 0,
        daemonFootprintBytes: UInt64 = 0,
        vmFootprintBytes: UInt64 = 0,
        cpuPercent: Double = 0
    ) {
        self.footprintBytes = footprintBytes
        self.rssBytes = rssBytes
        self.daemonFootprintBytes = daemonFootprintBytes
        self.vmFootprintBytes = vmFootprintBytes
        self.cpuPercent = cpuPercent
    }

    public static func samplePID(_ pid: Int32) -> (footprint: UInt64, rss: UInt64)? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rptr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rptr)
            }
        }
        if rc == 0 {
            return (info.ri_phys_footprint, info.ri_resident_size)
        }
        return nil
    }

    private static let cpuLock = NSLock()
    private static var prevSampleAt: Date?
    private static var prevCPUNanos: UInt64 = 0

    private static func cpuNanos(for pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rptr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rptr)
            }
        }
        guard rc == 0 else { return nil }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let denom = UInt64(max(1, tb.denom))
        let ticks = info.ri_user_time &+ info.ri_system_time
        return (ticks / denom) &* UInt64(tb.numer)
    }

    private static func samplePsMetrics(pids: [Int32]) -> (rssBytes: UInt64, cpuPercent: Double) {
        guard !pids.isEmpty else { return (0, 0) }
        let pidList = pids.map(String.init).joined(separator: ",")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", pidList, "-o", "rss=,%cpu="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return (0, 0) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return (0, 0) }
        var rss: UInt64 = 0
        var cpu: Double = 0
        for line in text.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0.isWhitespace })
            if let first = cols.first, let kb = UInt64(first) {
                rss &+= kb * 1024
            }
            if cols.count >= 2, let c = Double(cols[1]) {
                cpu += c
            }
        }
        return (rss, cpu)
    }

    private static func pidPath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    private static func listAllPIDs() -> [Int32] {
        let byteCap = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCap > 0 else { return [] }
        let count = Int(byteCap) / MemoryLayout<Int32>.size + 64
        var pids = [Int32](repeating: 0, count: count)
        let actualBytes = pids.withUnsafeMutableBytes { ptr in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, ptr.baseAddress, Int32(ptr.count))
        }
        guard actualBytes > 0 else { return [] }
        let n = min(pids.count, Int(actualBytes) / MemoryLayout<Int32>.size)
        return Array(pids[0..<n]).filter { $0 > 0 }
    }

    public static func current(daemonPID: Int32?, extraPIDs: [Int32] = []) -> HostProcessMetrics {
        guard let daemonPID, daemonPID > 0 else { return HostProcessMetrics() }
        var daemonFootprint: UInt64 = 0
        var vmFootprint: UInt64 = 0
        var totalRSS: UInt64 = 0
        var totalCPUNanos: UInt64 = 0

        for p in [daemonPID] + extraPIDs where p > 0 {
            if let s = samplePID(p) {
                daemonFootprint &+= s.footprint
                totalRSS &+= s.rss
            }
            if let c = cpuNanos(for: p) {
                totalCPUNanos &+= c
            }
        }

        var vmPIDs: [Int32] = []
        var vmCPUFallbackNeeded = false
        for pid in listAllPIDs() where pid != daemonPID {
            if let path = pidPath(pid), path.contains("com.apple.Virtualization.VirtualMachine") || path.hasSuffix("/krunkit") {
                vmPIDs.append(pid)
                if let sample = samplePID(pid) {
                    vmFootprint &+= sample.footprint
                    totalRSS &+= sample.rss
                    if let c = cpuNanos(for: pid) {
                        totalCPUNanos &+= c
                    } else {
                        vmCPUFallbackNeeded = true
                    }
                } else {
                    vmCPUFallbackNeeded = true
                }
            }
        }

        var vmCPUFallback: Double = 0
        if !vmPIDs.isEmpty && (vmFootprint == 0 || vmCPUFallbackNeeded) {
            let psRes = samplePsMetrics(pids: vmPIDs)
            if vmFootprint == 0 {
                vmFootprint &+= psRes.rssBytes
                totalRSS &+= psRes.rssBytes
            }
            vmCPUFallback = psRes.cpuPercent
        }

        let now = Date()
        var cpuPct = vmCPUFallback
        cpuLock.lock()
        if let prevAt = prevSampleAt {
            let dt = now.timeIntervalSince(prevAt)
            if dt >= 0.05 && totalCPUNanos >= prevCPUNanos {
                cpuPct += Double(totalCPUNanos - prevCPUNanos) / (dt * 1_000_000_000.0) * 100.0
            }
        }
        prevSampleAt = now
        prevCPUNanos = totalCPUNanos
        cpuLock.unlock()

        return HostProcessMetrics(
            footprintBytes: daemonFootprint &+ vmFootprint,
            rssBytes: totalRSS,
            daemonFootprintBytes: daemonFootprint,
            vmFootprintBytes: vmFootprint,
            cpuPercent: (cpuPct * 10.0).rounded() / 10.0
        )
    }
}

public enum FirnHostClient {
    public static func metalGPUDeviceName() -> String? {
        guard let dev = MTLCreateSystemDefaultDevice() else { return nil }
        return dev.name
    }

    public static func sha256Hex(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(ptr.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func formatBytes(_ numBytes: UInt64) -> String {
        let mib = Double(numBytes) / (1024.0 * 1024.0)
        if mib >= 1024.0 {
            return String(format: "%.2f GiB", mib / 1024.0)
        }
        return String(format: "%.1f MiB", mib)
    }

    public static func readDaemonPID() -> Int32? {
        guard let text = try? String(contentsOf: FirnPaths.pidFileURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else {
            return nil
        }
        return pid
    }

    public static func isDaemonAlive() -> Bool {
        guard let pid = readDaemonPID() else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    public static func hostSparseFileStats(at url: URL = FirnPaths.dataDiskURL) -> (logicalBytes: UInt64, allocatedBytes: UInt64) {
        var st = Darwin.stat()
        guard Darwin.lstat(url.path, &st) == 0 else {
            return (0, 0)
        }
        let logical = st.st_size > 0 ? UInt64(st.st_size) : 0
        let allocated = st.st_blocks > 0 ? UInt64(st.st_blocks) * 512 : 0
        return (logical, allocated)
    }

    public static func requestData(
        method: String,
        path: String,
        body: Data? = nil,
        socketURL: URL = FirnPaths.hostSockURL,
        timeoutSeconds: Int = 60
    ) throws -> (status: Int, body: Data) {
        let sockPath = socketURL.path
        guard FileManager.default.fileExists(atPath: sockPath) else {
            throw NSError(
                domain: "Firn",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey: "Firn control socket \(sockPath) not found. Run `firn up` first."]
            )
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }

        var tv = timeval(tv_sec: max(1, timeoutSeconds), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(sockPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw NSError(domain: "Firn", code: 101, userInfo: [NSLocalizedDescriptionKey: "Socket path too long: \(sockPath)"])
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() {
                raw[i] = UInt8(bitPattern: b)
            }
        }
        let addrLen = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addrLen)
            }
        }
        guard rc == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var req = "\(method) \(path) HTTP/1.1\r\nHost: firn\r\nConnection: close\r\n"
        if let body {
            req += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        req += "\r\n"
        var reqData = Data(req.utf8)
        if let body, !body.isEmpty {
            reqData.append(body)
        }
        let wrote = reqData.withUnsafeBytes { rawPtr -> Bool in
            guard let base = rawPtr.baseAddress else { return false }
            var offset = 0
            while offset < rawPtr.count {
                let n = write(fd, base.advanced(by: offset), rawPtr.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard wrote else {
            throw NSError(domain: "Firn", code: 102, userInfo: [NSLocalizedDescriptionKey: "Failed writing request to firnd"])
        }

        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = buf.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            raw.append(buf, count: n)
        }

        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw NSError(domain: "Firn", code: 103, userInfo: [NSLocalizedDescriptionKey: "Malformed response from firnd"])
        }
        let header = String(data: raw[..<split.lowerBound], encoding: .utf8) ?? ""
        let firstLine = header.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        let statusCode = parts.count >= 2 ? (Int(parts[1]) ?? 500) : 500
        return (statusCode, Data(raw[split.upperBound...]))
    }

    public static func requestJSON(
        method: String,
        path: String,
        body: Data? = nil,
        socketURL: URL = FirnPaths.hostSockURL,
        timeoutSeconds: Int = 60
    ) throws -> [String: Any] {
        let (status, respBody) = try requestData(method: method, path: path, body: body, socketURL: socketURL, timeoutSeconds: timeoutSeconds)
        let decoded = (respBody.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: respBody)) as? [String: Any]) ?? [:]
        if status >= 400 {
            let msg = (decoded["error"] as? String) ?? "HTTP \(status)"
            throw NSError(domain: "Firn", code: status, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return decoded
    }
}
