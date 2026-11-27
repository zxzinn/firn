import Darwin
import Foundation
import FirnCore

public final class HostNetSupervisor {
    private let config: FirnConfig
    private let binURL: URL
    private var proc: Process?
    private var logHandle: FileHandle?
    private let lock = NSLock()
    private var running = false

    public var childPID: Int32 {
        lock.lock()
        let p = proc?.processIdentifier ?? 0
        lock.unlock()
        return p
    }

    public var isRunning: Bool {
        lock.lock()
        let ok = running && (proc?.isRunning ?? false)
        lock.unlock()
        return ok
    }

    public static func locateBinary() -> URL? {
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for candidate in [
            exeDir.appendingPathComponent("firn-hostnet"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/firn-hostnet"),
        ] {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("firn-hostnet")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    public init?(config: FirnConfig) {
        guard let bin = Self.locateBinary() else {
            return nil
        }
        self.config = config
        self.binURL = bin
    }

    public func start() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: FirnPaths.runDir, withIntermediateDirectories: true)
        _ = try? CertAuthority.ensureCA()

        unlink(FirnPaths.hostnetSockURL.path)
        unlink(FirnPaths.vmnetFDSockURL.path)
        unlink(FirnPaths.firnfsSockURL.path)

        fm.createFile(atPath: FirnPaths.hostnetLogURL.path, contents: nil)
        let lh = try FileHandle(forWritingTo: FirnPaths.hostnetLogURL)
        try lh.truncate(atOffset: 0)
        self.logHandle = lh

        let p = Process()
        p.executableURL = binURL
        p.arguments = [
            "--host-home", fm.homeDirectoryForCurrentUser.path,
            "--vmnet-fd-sock", FirnPaths.vmnetFDSockURL.path,
            "--firnfs-sock", FirnPaths.firnfsSockURL.path,
            "--control-sock", FirnPaths.hostnetSockURL.path,
            "--firnd-sock", FirnPaths.hostSockURL.path,
            "--utun-sock", FirnPaths.utunSockURL.path,
            "--domain", config.domain,
            "--http-proxy-port", String(config.httpProxyPort),
            "--https-proxy-port", String(config.httpsProxyPort),
            "--ca-cert", FirnPaths.caCertURL.path,
            "--ca-key", FirnPaths.caKeyURL.path,
            "--port-forward=false",
            "--mtu", "16384",
        ]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = lh
        p.standardError = lh

        lock.lock()
        self.proc = p
        self.running = true
        lock.unlock()
        try p.run()

        let deadline = Date().addingTimeInterval(6.0)
        while Date() < deadline {
            if fm.fileExists(atPath: FirnPaths.hostnetSockURL.path),
               fm.fileExists(atPath: FirnPaths.vmnetFDSockURL.path),
               fm.fileExists(atPath: FirnPaths.firnfsSockURL.path) {
                return
            }
            if !p.isRunning {
                throw NSError(domain: "FirnHostNet", code: 1, userInfo: [NSLocalizedDescriptionKey: "firn-hostnet exited prematurely"])
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw NSError(domain: "FirnHostNet", code: 2, userInfo: [NSLocalizedDescriptionKey: "firn-hostnet sockets did not become ready"])
    }

    public func sendVMNetSocketFD(_ fdToSend: Int32) throws {
        defer { Darwin.close(fdToSend) }
        let sockPath = FirnPaths.vmnetFDSockURL.path
        let sockFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sockFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(sockFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(sockPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw NSError(domain: "FirnHostNet", code: 3, userInfo: [NSLocalizedDescriptionKey: "vmnet-fd socket path too long"])
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let len = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + bytes.count)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sockFD, $0, len) }
        }
        guard rc == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        // Send 1 byte + SCM_RIGHTS file descriptor.
        var dummyByte: UInt8 = 0x46
        let cmsgHdrSize = MemoryLayout<cmsghdr>.stride
        let payloadSize = MemoryLayout<Int32>.stride
        let alignedCmsgSize = ((cmsgHdrSize + payloadSize + 7) / 8) * 8
        var controlBuf = [UInt8](repeating: 0, count: alignedCmsgSize)

        let sendRes: Int = withUnsafeMutablePointer(to: &dummyByte) { dataPtr in
            var iov = iovec(iov_base: UnsafeMutableRawPointer(dataPtr), iov_len: 1)
            return controlBuf.withUnsafeMutableBytes { cRaw in
                withUnsafeMutablePointer(to: &iov) { iovPtr in
                    var msg = msghdr()
                    msg.msg_iov = iovPtr
                    msg.msg_iovlen = 1
                    msg.msg_control = cRaw.baseAddress
                    msg.msg_controllen = socklen_t(cRaw.count)

                    let hdrPtr = cRaw.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
                    hdrPtr.pointee.cmsg_len = socklen_t(cmsgHdrSize + payloadSize)
                    hdrPtr.pointee.cmsg_level = SOL_SOCKET
                    hdrPtr.pointee.cmsg_type = SCM_RIGHTS

                    var fdCopy = fdToSend
                    cRaw.baseAddress!.advanced(by: cmsgHdrSize).copyMemory(from: &fdCopy, byteCount: payloadSize)
                    return Darwin.sendmsg(sockFD, &msg, 0)
                }
            }
        }
        guard sendRes == 1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var ack: UInt8 = 1
        _ = Darwin.read(sockFD, &ack, 1)
    }

    public func pushTopology(_ payloadData: Data) {
        guard isRunning else { return }
        _ = try? FirnHostClient.requestData(
            method: "POST",
            path: "/topology",
            body: payloadData,
            socketURL: FirnPaths.hostnetSockURL,
            timeoutSeconds: 5
        )
    }

    public func pushDNSServers(_ servers: [String]) {
        guard isRunning else { return }
        guard let body = try? JSONSerialization.data(withJSONObject: ["servers": servers]) else { return }
        _ = try? FirnHostClient.requestData(
            method: "POST",
            path: "/dns-servers",
            body: body,
            socketURL: FirnPaths.hostnetSockURL,
            timeoutSeconds: 3
        )
    }

    public func pushFSEvents(_ relPaths: [String]) {
        guard isRunning, !relPaths.isEmpty else { return }
        guard let body = try? JSONSerialization.data(withJSONObject: ["paths": relPaths]) else { return }
        _ = try? FirnHostClient.requestData(
            method: "POST",
            path: "/fsevents",
            body: body,
            socketURL: FirnPaths.hostnetSockURL,
            timeoutSeconds: 3
        )
    }

    public func fetchStatus() -> [String: Any]? {
        guard isRunning else { return nil }
        return try? FirnHostClient.requestJSON(
            method: "GET",
            path: "/status",
            socketURL: FirnPaths.hostnetSockURL,
            timeoutSeconds: 2
        )
    }

    public func stop() {
        lock.lock()
        running = false
        let p = proc
        proc = nil
        lock.unlock()
        if let p, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(2.0)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning {
                _ = Darwin.kill(p.processIdentifier, SIGKILL)
            }
        }
        try? logHandle?.close()
        logHandle = nil
    }
}
