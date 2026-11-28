import Darwin
import Foundation
import FirnCore
import SystemConfiguration

private final class IOThreadPool {
    static let shared = IOThreadPool()
    private let cond = NSCondition()
    private var queue: [() -> Void] = []
    private var idleWorkers = 0
    private let maxIdleWorkers = 32
    private let idleTimeout: TimeInterval = 30.0

    func submit(_ work: @escaping () -> Void) {
        cond.lock()
        queue.append(work)
        if idleWorkers > 0 {
            cond.signal()
            cond.unlock()
            return
        }
        cond.unlock()
        Thread.detachNewThread { [self] in
            self.workerLoop()
        }
    }

    private func workerLoop() {
        while true {
            var task: (() -> Void)?
            cond.lock()
            if queue.isEmpty {
                idleWorkers += 1
                let deadline = Date().addingTimeInterval(idleTimeout)
                while queue.isEmpty {
                    if !cond.wait(until: deadline) {
                        break
                    }
                }
                idleWorkers = max(0, idleWorkers - 1)
                if queue.isEmpty && idleWorkers >= maxIdleWorkers {
                    cond.unlock()
                    return
                }
                if queue.isEmpty {
                    // Timed out idle.
                    cond.unlock()
                    return
                }
            }
            if !queue.isEmpty {
                task = queue.removeFirst()
            }
            cond.unlock()
            task?()
        }
    }
}

public func spawnIOThread(_ body: @escaping () -> Void) {
    IOThreadPool.shared.submit(body)
}

private func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0 {
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}

private func setBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0 {
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    }
}

private func tuneStreamSocket(_ fd: Int32) {
    var yes: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    for bufBytes in [Int32(8 << 20), Int32(4 << 20), Int32(2 << 20), Int32(1 << 20)] {
        var val = bufBytes
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &val, socklen_t(MemoryLayout<Int32>.size))
        if setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &val, socklen_t(MemoryLayout<Int32>.size)) == 0 {
            break
        }
    }
}

public func configureClientSocket(_ fd: Int32) {
    tuneStreamSocket(fd)
    var yes: Int32 = 1
    _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
}

private func writeRawExact(fd: Int32, base: UnsafeRawPointer, count: Int) -> Bool {
    var off = 0
    while off < count {
        let w = Darwin.write(fd, base.advanced(by: off), count - off)
        if w > 0 {
            off += w
            continue
        }
        if w < 0 && errno == EINTR {
            continue
        }
        return false
    }
    return true
}

private final class StreamBufferPool {
    static let shared = StreamBufferPool()
    let bufferSize = 2 << 20
    private let lock = NSLock()
    private var free: [UnsafeMutableRawPointer] = []
    private let maxCached = 24

    func borrow() -> UnsafeMutableRawPointer {
        lock.lock()
        let ptr = free.popLast()
        lock.unlock()
        return ptr ?? UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 4096)
    }

    func recycle(_ ptr: UnsafeMutableRawPointer) {
        lock.lock()
        if free.count < maxCached {
            free.append(ptr)
            lock.unlock()
        } else {
            lock.unlock()
            ptr.deallocate()
        }
    }
}

private func streamOneDirection(srcFD: Int32, dstFD: Int32) {
    let pool = StreamBufferPool.shared
    let buf = pool.borrow()
    let bufSize = pool.bufferSize
    defer { pool.recycle(buf) }

    while true {
        let n = Darwin.read(srcFD, buf, bufSize)
        if n < 0 && errno == EINTR {
            continue
        }
        if n <= 0 {
            _ = Darwin.shutdown(dstFD, SHUT_WR)
            return
        }
        if !writeRawExact(fd: dstFD, base: buf, count: n) {
            _ = Darwin.shutdown(srcFD, SHUT_RD)
            _ = Darwin.shutdown(dstFD, SHUT_WR)
            return
        }
    }
}

public func spliceBidirectional(fd unixFD: Int32, vsockConn: any StreamChannel) {
    let aFD = unixFD
    let bFD = vsockConn.fileDescriptor
    setBlocking(aFD)
    setBlocking(bFD)
    tuneStreamSocket(aFD)
    tuneStreamSocket(bFD)

    let group = DispatchGroup()
    group.enter()
    spawnIOThread {
        streamOneDirection(srcFD: aFD, dstFD: bFD)
        group.leave()
    }
    group.enter()
    spawnIOThread {
        streamOneDirection(srcFD: bFD, dstFD: aFD)
        group.leave()
    }

    withExtendedLifetime(vsockConn) {
        group.wait()
        close(aFD)
        vsockConn.close()
    }
}

public func bindUnixSocket(at url: URL) throws -> Int32 {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    unlink(url.path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(url.path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        close(fd)
        throw NSError(domain: "Firn", code: 10, userInfo: [NSLocalizedDescriptionKey: "Socket path too long: \(url.path)"])
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, byte) in pathBytes.enumerated() {
            raw[i] = UInt8(bitPattern: byte)
        }
    }
    let len = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, len)
        }
    }
    guard rc == 0, listen(fd, 512) == 0 else {
        let err = errno
        close(fd)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
    }
    chmod(url.path, 0o600)
    return fd
}

public func connectHostTCP(host: String, port: UInt16, timeoutSeconds: Int = 5) -> Int32 {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    hints.ai_family = AF_UNSPEC
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
        return -1
    }
    defer { freeaddrinfo(first) }
    var ipv4Nodes: [UnsafeMutablePointer<addrinfo>] = []
    var otherNodes: [UnsafeMutablePointer<addrinfo>] = []
    var cur: UnsafeMutablePointer<addrinfo>? = first
    while let node = cur {
        if node.pointee.ai_family == AF_INET {
            ipv4Nodes.append(node)
        } else {
            otherNodes.append(node)
        }
        cur = node.pointee.ai_next
    }
    for node in ipv4Nodes + otherNodes {
        let fd = socket(node.pointee.ai_family, node.pointee.ai_socktype, node.pointee.ai_protocol)
        if fd < 0 { continue }
        configureClientSocket(fd)
        setNonBlocking(fd)
        let rc = Darwin.connect(fd, node.pointee.ai_addr, node.pointee.ai_addrlen)
        if rc == 0 {
            setBlocking(fd)
            return fd
        }
        if errno == EINPROGRESS {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&pfd, 1, Int32(max(1, timeoutSeconds) * 1000))
            if pr > 0 && (pfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) == 0 {
                var soErr: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0 && soErr == 0 {
                    setBlocking(fd)
                    return fd
                }
            }
        }
        close(fd)
    }
    return -1
}

public func writeAll(fd: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return true }
        var offset = 0
        while offset < raw.count {
            let n = write(fd, base.advanced(by: offset), raw.count - offset)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

public final class VsockBridge {
    private let runner: any VMBackend
    private var dockerListenFD: Int32 = -1
    private var shellListenFD: Int32 = -1
    private var running = false
    private let sessionLock = NSLock()
    private var _activeSessions = 0

    public var activeSessionCount: Int {
        sessionLock.lock()
        let v = _activeSessions
        sessionLock.unlock()
        return v
    }

    private func trackSession(_ body: () -> Void) {
        sessionLock.lock()
        _activeSessions += 1
        sessionLock.unlock()
        defer {
            sessionLock.lock()
            _activeSessions = max(0, _activeSessions - 1)
            sessionLock.unlock()
        }
        body()
    }

    public init(runner: any VMBackend) {
        self.runner = runner
    }

    public func startDockerSocketBridge() throws {
        dockerListenFD = try bindUnixSocket(at: FirnPaths.dockerSockURL)
        running = true
        spawnIOThread { [weak self] in
            guard let self else { return }
            while self.running {
                let clientFD = accept(self.dockerListenFD, nil, nil)
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    break
                }
                spawnIOThread {
                    self.trackSession {
                        do {
                            let vsockConn = try self.runner.connectVsock(port: 2375, timeoutSeconds: 15.0)
                            spliceBidirectional(fd: clientFD, vsockConn: vsockConn)
                        } catch {
                            close(clientFD)
                        }
                    }
                }
            }
        }
    }

    public func startShellSocketBridge() throws {
        shellListenFD = try bindUnixSocket(at: FirnPaths.shellSockURL)
        running = true
        spawnIOThread { [weak self] in
            guard let self else { return }
            while self.running {
                let clientFD = accept(self.shellListenFD, nil, nil)
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    break
                }
                spawnIOThread {
                    self.trackSession {
                        do {
                            let vsockConn = try self.runner.connectVsock(port: 2382, timeoutSeconds: 15.0)
                            spliceBidirectional(fd: clientFD, vsockConn: vsockConn)
                        } catch {
                            close(clientFD)
                        }
                    }
                }
            }
        }
    }

    public func startHostRelays() {
        // Port 2378: guest outbound HTTP/CONNECT proxy -> macOS host VPN / corporate proxy.
        runner.registerSocketListener(port: 2378) { conn in
            spawnIOThread {
                Self.handleGuestProxyConnection(conn)
            }
        }
        // Port 2379: guest DNS relay -> macOS active DNS servers (including VPN split-DNS).
        runner.registerSocketListener(port: 2379) { conn in
            spawnIOThread {
                Self.handleGuestDNSConnection(conn)
            }
        }
        // Port 2380: guest netstack outbound TCP -> macOS host routing/VPN.
        runner.registerSocketListener(port: 2380) { conn in
            spawnIOThread {
                Self.handleNetstackTCPConnection(conn)
            }
        }
        // Port 2381: guest netstack outbound UDP -> macOS host UDP socket.
        runner.registerSocketListener(port: 2381) { conn in
            spawnIOThread {
                Self.handleNetstackUDPConnection(conn)
            }
        }
        // Port 2383: guest SSH agent relay -> host SSH_AUTH_SOCK.
        runner.registerSocketListener(port: 2383) { conn in
            spawnIOThread {
                Self.handleSSHAgentConnection(conn)
            }
        }
        // Port 2385: firnfs RPC & FSEvents invalidation stream -> firn-hostnet firnfs.sock.
        runner.registerSocketListener(port: 2385) { conn in
            spawnIOThread {
                Self.relayUnixSocketConnection(conn, socketPath: FirnPaths.firnfsSockURL.path)
            }
        }
    }

    public func guestHTTP(method: String, path: String, body: Data? = nil, timeoutSeconds: Double = 15.0) throws -> (status: Int, body: Data) {
        let conn = try runner.connectVsock(port: 2376, timeoutSeconds: timeoutSeconds)
        defer {
            withExtendedLifetime(conn) { conn.close() }
        }
        let fd = conn.fileDescriptor
        var req = "\(method) \(path) HTTP/1.1\r\nHost: firn-guest\r\nConnection: close\r\n"
        if let body {
            req += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        req += "\r\n"
        guard writeAll(fd: fd, data: Data(req.utf8)) else {
            throw NSError(domain: "Firn", code: 20, userInfo: [NSLocalizedDescriptionKey: "Failed writing vsock HTTP request"])
        }
        if let body, !body.isEmpty, !writeAll(fd: fd, data: body) {
            throw NSError(domain: "Firn", code: 21, userInfo: [NSLocalizedDescriptionKey: "Failed writing vsock HTTP body"])
        }

        var tv = timeval(tv_sec: max(5, Int(ceil(timeoutSeconds))), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            raw.append(buf, count: n)
        }
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw NSError(domain: "Firn", code: 22, userInfo: [NSLocalizedDescriptionKey: "Malformed HTTP response from firn-guestd"])
        }
        let headerStr = String(data: raw[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        let firstLine = headerStr.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let statusParts = firstLine.split(separator: " ")
        let statusCode = statusParts.count >= 2 ? (Int(statusParts[1]) ?? 500) : 500
        let payload = raw[headerEnd.upperBound...]
        if headerStr.lowercased().contains("transfer-encoding: chunked") {
            return (statusCode, Self.decodeChunked(Data(payload)))
        }
        return (statusCode, Data(payload))
    }

    public func openTunnel(host: String, port: UInt16) throws -> any StreamChannel {
        let hostData = Data(host.utf8)
        guard hostData.count > 0 && hostData.count <= 255 else {
            throw NSError(domain: "Firn", code: 30, userInfo: [NSLocalizedDescriptionKey: "Invalid tunnel host"])
        }
        let conn = try runner.connectVsock(port: 2377, timeoutSeconds: 5.0)
        var header = Data([0x01, UInt8(hostData.count)])
        header.append(hostData)
        var bePort = port.bigEndian
        withUnsafeBytes(of: &bePort) { header.append(contentsOf: $0) }
        guard writeAll(fd: conn.fileDescriptor, data: header) else {
            conn.close()
            throw NSError(domain: "Firn", code: 31, userInfo: [NSLocalizedDescriptionKey: "Failed sending tunnel header"])
        }
        var reply: UInt8 = 1
        let n = read(conn.fileDescriptor, &reply, 1)
        guard n == 1 && reply == 0x00 else {
            conn.close()
            throw NSError(domain: "Firn", code: 32, userInfo: [NSLocalizedDescriptionKey: "Guest refused tunnel to \(host):\(port)"])
        }
        return conn
    }

    public func stop() {
        running = false
        if dockerListenFD >= 0 {
            close(dockerListenFD)
            dockerListenFD = -1
        }
        if shellListenFD >= 0 {
            close(shellListenFD)
            shellListenFD = -1
        }
        unlink(FirnPaths.dockerSockURL.path)
        unlink(FirnPaths.shellSockURL.path)
    }

    private static func readNetstackTunnelHeader(_ fd: Int32) -> (proto: UInt8, host: String, port: UInt16)? {
        guard let head = readExact(fd: fd, count: 2) else { return nil }
        let proto = head[0]
        let hostLen = Int(head[1])
        guard hostLen > 0,
              let hostBytes = readExact(fd: fd, count: hostLen),
              let portBytes = readExact(fd: fd, count: 2),
              let host = String(data: hostBytes, encoding: .utf8) else {
            return nil
        }
        let port = (UInt16(portBytes[0]) << 8) | UInt16(portBytes[1])
        guard port > 0 else { return nil }
        return (proto, host, port)
    }

    private static func handleNetstackTCPConnection(_ conn: any StreamChannel) {
        let fd = conn.fileDescriptor
        guard let target = readNetstackTunnelHeader(fd), target.proto == 0x01 else {
            _ = writeAll(fd: fd, data: Data([0x01]))
            withExtendedLifetime(conn) { conn.close() }
            return
        }
        let upFD = connectHostTCP(host: target.host, port: target.port, timeoutSeconds: 8)
        guard upFD >= 0 else {
            _ = writeAll(fd: fd, data: Data([0x01]))
            withExtendedLifetime(conn) { conn.close() }
            return
        }
        guard writeAll(fd: fd, data: Data([0x00])) else {
            close(upFD)
            withExtendedLifetime(conn) { conn.close() }
            return
        }
        spliceBidirectional(fd: upFD, vsockConn: conn)
    }

    private static func handleNetstackUDPConnection(_ conn: any StreamChannel) {
        let fd = conn.fileDescriptor
        defer { withExtendedLifetime(conn) { conn.close() } }
        guard let target = readNetstackTunnelHeader(fd), target.proto == 0x02 else {
            _ = writeAll(fd: fd, data: Data([0x01]))
            return
        }

        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_family = AF_INET
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(target.host, String(target.port), &hints, &res) == 0, let first = res else {
            _ = writeAll(fd: fd, data: Data([0x01]))
            return
        }
        defer { freeaddrinfo(first) }

        let udpFD = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard udpFD >= 0 else {
            _ = writeAll(fd: fd, data: Data([0x01]))
            return
        }
        defer { close(udpFD) }

        guard Darwin.connect(udpFD, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
            _ = writeAll(fd: fd, data: Data([0x01]))
            return
        }
        guard writeAll(fd: fd, data: Data([0x00])) else {
            return
        }

        var lenBuf = [UInt8](repeating: 0, count: 2)
        var dgramBuf = [UInt8](repeating: 0, count: 65536)
        while true {
            var fds = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: udpFD, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&fds, 2, 30_000)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                break
            }
            if (fds[0].revents & Int16(POLLIN)) != 0 {
                guard let lh = readExact(fd: fd, count: 2) else { break }
                let n = Int((UInt16(lh[0]) << 8) | UInt16(lh[1]))
                guard n > 0 && n <= dgramBuf.count, let payload = readExact(fd: fd, count: n) else { break }
                let sent = payload.withUnsafeBytes { raw in
                    Darwin.send(udpFD, raw.baseAddress, payload.count, 0)
                }
                if sent < 0 { break }
            }
            if (fds[1].revents & Int16(POLLIN)) != 0 {
                let n = dgramBuf.withUnsafeMutableBytes { raw in
                    Darwin.recv(udpFD, raw.baseAddress, raw.count, 0)
                }
                if n <= 0 { break }
                lenBuf[0] = UInt8((n >> 8) & 0xFF)
                lenBuf[1] = UInt8(n & 0xFF)
                var pkt = Data(lenBuf)
                pkt.append(contentsOf: dgramBuf[0..<n])
                if !writeAll(fd: fd, data: pkt) { break }
            }
            if ((fds[0].revents | fds[1].revents) & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
                if (fds[0].revents & Int16(POLLIN)) == 0 && (fds[1].revents & Int16(POLLIN)) == 0 {
                    break
                }
            }
        }
    }

    private static func handleSSHAgentConnection(_ conn: any StreamChannel) {
        guard let sockPath = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !sockPath.isEmpty else {
            withExtendedLifetime(conn) { conn.close() }
            return
        }
        relayUnixSocketConnection(conn, socketPath: sockPath)
    }

    private static func relayUnixSocketConnection(_ conn: any StreamChannel, socketPath: String) {
        let unixFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard unixFD >= 0 else {
            withExtendedLifetime(conn) { conn.close() }
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(unixFD)
            withExtendedLifetime(conn) { conn.close() }
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() {
                raw[i] = UInt8(bitPattern: b)
            }
        }
        let len = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(unixFD, $0, len)
            }
        }
        guard rc == 0 else {
            close(unixFD)
            withExtendedLifetime(conn) { conn.close() }
            return
        }
        spliceBidirectional(fd: unixFD, vsockConn: conn)
    }

    private static func decodeChunked(_ data: Data) -> Data {
        var out = Data()
        var cursor = data.startIndex
        let crlf = Data("\r\n".utf8)
        while cursor < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: cursor..<data.endIndex) else { break }
            let sizeStr = String(data: data[cursor..<lineEnd.lowerBound], encoding: .utf8)?
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let chunkStart = lineEnd.upperBound
            let chunkEnd = min(data.endIndex, chunkStart + size)
            out.append(data[chunkStart..<chunkEnd])
            cursor = min(data.endIndex, chunkEnd + 2)
        }
        return out
    }

    private static func handleGuestProxyConnection(_ conn: any StreamChannel) {
        let fd = conn.fileDescriptor
        var headerBuf = Data()
        var byteBuf = [UInt8](repeating: 0, count: 4096)
        let delim = Data("\r\n\r\n".utf8)
        var splitRange: Range<Data.Index>?
        while headerBuf.count < 65536 {
            let n = read(fd, &byteBuf, byteBuf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 {
                withExtendedLifetime(conn) { conn.close() }
                return
            }
            headerBuf.append(byteBuf, count: n)
            if let found = headerBuf.range(of: delim) {
                splitRange = found
                break
            }
        }
        guard let found = splitRange,
              let headerStr = String(data: headerBuf[..<found.lowerBound], encoding: .utf8) else {
            withExtendedLifetime(conn) { conn.close() }
            return
        }
        let remainder = Data(headerBuf[found.upperBound...])
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let reqLine = lines.first else {
            withExtendedLifetime(conn) { conn.close() }
            return
        }
        let parts = reqLine.split(separator: " ")
        guard parts.count >= 3 else {
            withExtendedLifetime(conn) { conn.close() }
            return
        }
        let method = String(parts[0])
        let target = String(parts[1])
        let proxyState = ProxyInspector.currentState()

        // If host macOS defines an HTTP/HTTPS proxy, forward entire raw request to it directly.
        if let upstreamURLString = (method == "CONNECT" ? (!proxyState.httpsProxy.isEmpty ? proxyState.httpsProxy : proxyState.httpProxy) : (!proxyState.httpProxy.isEmpty ? proxyState.httpProxy : nil)),
           let upstreamURL = URL(string: upstreamURLString),
           let proxyHost = upstreamURL.host {
            let proxyPort = UInt16(upstreamURL.port ?? (upstreamURL.scheme == "https" ? 443 : 80))
            let upFD = connectHostTCP(host: proxyHost, port: proxyPort)
            guard upFD >= 0, writeAll(fd: upFD, data: headerBuf) else {
                if upFD >= 0 { close(upFD) }
                _ = writeAll(fd: fd, data: Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
                withExtendedLifetime(conn) { conn.close() }
                return
            }
            spliceBidirectional(fd: upFD, vsockConn: conn)
            return
        }

        if method == "CONNECT" {
            let hostPort = splitHostPort(target, defaultPort: 443)
            let upFD = connectHostTCP(host: hostPort.host, port: hostPort.port)
            guard upFD >= 0 else {
                _ = writeAll(fd: fd, data: Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
                withExtendedLifetime(conn) { conn.close() }
                return
            }
            _ = writeAll(fd: fd, data: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            if !remainder.isEmpty {
                _ = writeAll(fd: upFD, data: remainder)
            }
            spliceBidirectional(fd: upFD, vsockConn: conn)
            return
        }

        guard let targetURL = URL(string: target), let destHost = targetURL.host else {
            _ = writeAll(fd: fd, data: Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
            withExtendedLifetime(conn) { conn.close() }
            return
        }
        let destPort = UInt16(targetURL.port ?? (targetURL.scheme == "https" ? 443 : 80))
        let upFD = connectHostTCP(host: destHost, port: destPort)
        guard upFD >= 0 else {
            _ = writeAll(fd: fd, data: Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            withExtendedLifetime(conn) { conn.close() }
            return
        }
        let pathAndQuery = (targetURL.path.isEmpty ? "/" : targetURL.path) + (targetURL.query.map { "?\($0)" } ?? "")
        var rewritten = "\(method) \(pathAndQuery) \(parts[2])\r\n"
        for line in lines.dropFirst() where !line.lowercased().hasPrefix("proxy-") {
            rewritten += line + "\r\n"
        }
        rewritten += "\r\n"
        var outbound = Data(rewritten.utf8)
        outbound.append(remainder)
        if !writeAll(fd: upFD, data: outbound) {
            close(upFD)
            withExtendedLifetime(conn) { conn.close() }
            return
        }
        spliceBidirectional(fd: upFD, vsockConn: conn)
    }

    private static func splitHostPort(_ raw: String, defaultPort: UInt16) -> (host: String, port: UInt16) {
        if raw.hasPrefix("["), let end = raw.firstIndex(of: "]") {
            let host = String(raw[raw.index(after: raw.startIndex)..<end])
            let rest = raw[raw.index(after: end)...]
            if rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) {
                return (host, p)
            }
            return (host, defaultPort)
        }
        if let colon = raw.lastIndex(of: ":"), let p = UInt16(raw[raw.index(after: colon)...]) {
            return (String(raw[..<colon]), p)
        }
        return (raw, defaultPort)
    }

    private static func handleGuestDNSConnection(_ conn: any StreamChannel) {
        defer { withExtendedLifetime(conn) { conn.close() } }
        let fd = conn.fileDescriptor
        guard let lenData = readExact(fd: fd, count: 2) else { return }
        let qlen = Int((UInt16(lenData[0]) << 8) | UInt16(lenData[1]))
        guard qlen > 0 && qlen <= 4096, let query = readExact(fd: fd, count: qlen) else { return }

        for serverIP in currentMacOSDNSServers() {
            if let resp = forwardUDPQuery(query, serverIP: serverIP) {
                var framed = Data([UInt8((resp.count >> 8) & 0xFF), UInt8(resp.count & 0xFF)])
                framed.append(resp)
                _ = writeAll(fd: fd, data: framed)
                return
            }
        }
    }

    private static func readExact(fd: Int32, count: Int) -> Data? {
        var out = Data(count: count)
        var readTotal = 0
        while readTotal < count {
            let n = out.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress!.advanced(by: readTotal), count - readTotal)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            readTotal += n
        }
        return out
    }

    public static func currentMacOSDNSServers() -> [String] {
        var result: [String] = []
        if let store = SCDynamicStoreCreate(nil, "firn-dns" as CFString, nil, nil),
           let dnsDict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
           let addrs = dnsDict["ServerAddresses"] as? [String] {
            for addr in addrs where addr.contains(".") && !addr.hasPrefix("127.") {
                result.append(addr)
            }
        }
        if !result.contains("1.1.1.1") { result.append("1.1.1.1") }
        if !result.contains("8.8.8.8") { result.append("8.8.8.8") }
        return result
    }

    private static func forwardUDPQuery(_ query: Data, serverIP: String) -> Data? {
        let udpFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard udpFD >= 0 else { return nil }
        defer { close(udpFD) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(udpFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, serverIP, &addr.sin_addr) == 1 else { return nil }

        let sent = query.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(udpFD, raw.baseAddress, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == query.count else { return nil }
        var respBuf = [UInt8](repeating: 0, count: 4096)
        let n = recv(udpFD, &respBuf, respBuf.count, 0)
        guard n > 0 else { return nil }
        return Data(respBuf[0..<n])
    }
}
