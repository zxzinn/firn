import Darwin
import Foundation
import FirnCore
import Virtualization

public struct PortMappingEntry: Codable, Sendable {
    public var hostPort: Int
    public var guestPort: Int
    public var guestHost: String
    public var project: String?
    public var service: String
    public var containerName: String
    public var containerIP: String?
    public var paused: Bool
}

private struct TopologyPayload: Codable {
    var version: UInt64
    var domain: String
    var ports: [PortMappingEntry]?
    var records: [DNSRecordEntry]?
}

public final class AutoThawProxy {
    private let bridge: VsockBridge
    private let balloon: BalloonController
    private let dnsServer: LocalDNSServer
    private let httpProxyPort: UInt16

    private let lock = NSLock()
    private var listeners: [Int: [Int32]] = [:]
    private var mappingsByPort: [Int: PortMappingEntry] = [:]
    private var topologyVersion: UInt64 = 0
    private let topoCond = NSCondition()
    private let thawCond = NSCondition()
    private var thawingProjects: Set<String> = []
    private var httpListenFDs: [Int32] = []
    private var lastKnownProjects: Set<String> = []
    private var running = false

    public var onProjectsChanged: (([String]) -> Void)?

    public init(bridge: VsockBridge, balloon: BalloonController, dnsServer: LocalDNSServer, httpProxyPort: UInt16) {
        self.bridge = bridge
        self.balloon = balloon
        self.dnsServer = dnsServer
        self.httpProxyPort = httpProxyPort
    }

    public func start() {
        running = true
        try? startHTTPDomainProxy()
        spawnIOThread { [weak self] in
            while self?.running == true {
                let ok = self?.syncTopology(longPoll: true) ?? false
                if !ok && self?.running == true {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
    }

    public func syncTopologyNow() {
        _ = syncTopology(longPoll: false)
    }

    public func currentTopologyVersion() -> UInt64 {
        topoCond.lock()
        let v = topologyVersion
        topoCond.unlock()
        return v
    }

    public func waitForTopologyChange(since: UInt64, timeoutSeconds: Double = 10.0) -> UInt64 {
        let clampedTimeout = max(0.0, min(15.0, timeoutSeconds))
        let deadline = Date().addingTimeInterval(clampedTimeout)
        topoCond.lock()
        while running && topologyVersion <= since && Date() < deadline {
            topoCond.wait(until: deadline)
        }
        let v = topologyVersion
        topoCond.unlock()
        return v
    }

    @discardableResult
    private func syncTopology(longPoll: Bool) -> Bool {
        topoCond.lock()
        let since = topologyVersion
        topoCond.unlock()

        let path = longPoll ? "/topology?since=\(since)&wait=10" : "/topology"
        let timeout = longPoll ? 15.0 : 5.0
        guard let (status, data) = try? bridge.guestHTTP(method: "GET", path: path, timeoutSeconds: timeout),
              status == 200,
              let payload = try? JSONDecoder().decode(TopologyPayload.self, from: data) else {
            return false
        }

        topoCond.lock()
        let changed = payload.version != topologyVersion
        if payload.version > topologyVersion {
            topologyVersion = payload.version
            topoCond.broadcast()
        }
        topoCond.unlock()

        if changed || !longPoll {
            let ports = payload.ports ?? []
            let records = payload.records ?? []
            reconcilePortListeners(ports)
            dnsServer.updateRecords(records)

            var projects = Set<String>()
            for r in records {
                if let p = r.project, !p.isEmpty { projects.insert(p) }
            }
            lock.lock()
            let projChanged = projects != lastKnownProjects
            if projChanged {
                lastKnownProjects = projects
            }
            lock.unlock()
            if projChanged {
                onProjectsChanged?(Array(projects).sorted())
            }
        }
        return true
    }

    public func currentPortMappings() -> [PortMappingEntry] {
        lock.lock()
        let copy = Array(mappingsByPort.values).sorted { $0.hostPort < $1.hostPort }
        lock.unlock()
        return copy
    }

    private func reconcilePortListeners(_ entries: [PortMappingEntry]) {
        var desired: [Int: PortMappingEntry] = [:]
        for entry in entries {
            desired[entry.hostPort] = entry
        }

        lock.lock()
        for (port, fds) in listeners where desired[port] == nil {
            for fd in fds { close(fd) }
            listeners.removeValue(forKey: port)
        }
        mappingsByPort = desired
        let toOpen = desired.keys.filter { listeners[$0] == nil }
        lock.unlock()

        for port in toOpen {
            guard port > 0 && port <= 65535 else { continue }
            let fds = Self.bindLoopbackDualStack(port: UInt16(port))
            if !fds.isEmpty {
                lock.lock()
                listeners[port] = fds
                lock.unlock()
                for fd in fds {
                    spawnIOThread { [weak self] in
                        self?.acceptPortLoop(hostPort: port, listenFD: fd)
                    }
                }
            }
        }
    }

    public static func bindLoopbackDualStack(port: UInt16) -> [Int32] {
        var bound: [Int32] = []

        // IPv4 loopback 127.0.0.1
        let fd4 = socket(AF_INET, SOCK_STREAM, 0)
        if fd4 >= 0 {
            var yes: Int32 = 1
            setsockopt(fd4, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr4 = sockaddr_in()
            addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr4.sin_family = sa_family_t(AF_INET)
            addr4.sin_port = port.bigEndian
            addr4.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let rc4 = withUnsafePointer(to: &addr4) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd4, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc4 == 0 && listen(fd4, 128) == 0 {
                bound.append(fd4)
            } else {
                close(fd4)
            }
        }

        // IPv6 loopback ::1
        let fd6 = socket(AF_INET6, SOCK_STREAM, 0)
        if fd6 >= 0 {
            var yes: Int32 = 1
            setsockopt(fd6, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd6, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr6 = sockaddr_in6()
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = port.bigEndian
            addr6.sin6_addr = in6addr_loopback
            let rc6 = withUnsafePointer(to: &addr6) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            if rc6 == 0 && listen(fd6, 128) == 0 {
                bound.append(fd6)
            } else {
                close(fd6)
            }
        }

        return bound
    }

    private func acceptPortLoop(hostPort: Int, listenFD: Int32) {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            configureClientSocket(clientFD)
            spawnIOThread { [weak self] in
                self?.forwardAcceptedClient(clientFD: clientFD, hostPort: hostPort)
            }
        }
    }

    public func openTunnelWithRetry(host: String, port: UInt16, attempts: Int = 5) throws -> VZVirtioSocketConnection {
        var lastErr: Error?
        for idx in 0..<max(1, attempts) {
            do {
                return try bridge.openTunnel(host: host, port: port)
            } catch {
                lastErr = error
                if idx + 1 < attempts {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }
        throw lastErr ?? NSError(domain: "Firn", code: 33, userInfo: [NSLocalizedDescriptionKey: "Tunnel open failed"])
    }

    private func forwardAcceptedClient(clientFD: Int32, hostPort: Int) {
        lock.lock()
        let entry = mappingsByPort[hostPort]
        lock.unlock()
        guard let entry else {
            close(clientFD)
            return
        }
        if entry.paused, let proj = entry.project {
            try? ensureThawed(project: proj, targetContainer: entry.containerName)
        }
        do {
            let useContainerIP = (entry.containerIP?.isEmpty == false)
            let destHost = useContainerIP ? entry.containerIP! : "127.0.0.1"
            let destPort = useContainerIP ? UInt16(entry.guestPort) : UInt16(entry.hostPort)
            let vsockConn = try openTunnelWithRetry(host: destHost, port: destPort)
            spliceBidirectional(fd: clientFD, vsockConn: vsockConn)
        } catch {
            close(clientFD)
        }
    }

    private func markLocalProjectUnpaused(_ project: String) {
        lock.lock()
        for (port, var entry) in mappingsByPort where entry.project == project {
            entry.paused = false
            mappingsByPort[port] = entry
        }
        lock.unlock()
        var recs = dnsServer.currentRecords()
        var dirty = false
        for idx in recs.indices where recs[idx].project == project && recs[idx].paused {
            recs[idx].paused = false
            dirty = true
        }
        if dirty {
            dnsServer.updateRecords(recs)
        }
        topoCond.lock()
        topologyVersion &+= 1
        topoCond.broadcast()
        topoCond.unlock()
    }

    public func ensureThawed(project: String, targetContainer: String? = nil) throws {
        thawCond.lock()
        if thawingProjects.contains(project) {
            while thawingProjects.contains(project) {
                thawCond.wait()
            }
            thawCond.unlock()
            return
        }
        thawingProjects.insert(project)
        thawCond.unlock()

        defer {
            thawCond.lock()
            thawingProjects.remove(project)
            thawCond.broadcast()
            thawCond.unlock()
        }

        balloon.ensureFullCapacityForThaw()
        let encodedProj = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project
        var path = "/thaw/\(encodedProj)"
        if let targetContainer, !targetContainer.isEmpty {
            let encodedTarget = targetContainer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? targetContainer
            path += "?target=\(encodedTarget)"
        }
        _ = try bridge.guestHTTP(method: "POST", path: path, timeoutSeconds: 15.0)
        markLocalProjectUnpaused(project)
        spawnIOThread { [weak self] in
            self?.syncTopologyNow()
        }
    }

    private func startHTTPDomainProxy() throws {
        let fds = Self.bindLoopbackDualStack(port: httpProxyPort)
        guard !fds.isEmpty else {
            throw NSError(domain: "Firn", code: 40, userInfo: [NSLocalizedDescriptionKey: "Cannot bind HTTP domain proxy port \(httpProxyPort)"])
        }
        httpListenFDs = fds
        for fd in fds {
            spawnIOThread { [weak self] in
                while self?.running == true {
                    let clientFD = accept(fd, nil, nil)
                    if clientFD < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    configureClientSocket(clientFD)
                    spawnIOThread {
                        self?.handleHTTPDomainClient(clientFD)
                    }
                }
            }
        }
    }

    private func handleHTTPDomainClient(_ clientFD: Int32) {
        var reqBuf = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        let delim = Data("\r\n\r\n".utf8)
        while reqBuf.count < 65536 {
            let n = read(clientFD, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { close(clientFD); return }
            reqBuf.append(chunk, count: n)
            if reqBuf.range(of: delim) != nil { break }
        }
        guard let headerEnd = reqBuf.range(of: delim),
              let headerStr = String(data: reqBuf[..<headerEnd.lowerBound], encoding: .utf8) else {
            close(clientFD)
            return
        }
        var hostHeader = ""
        for line in headerStr.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("host:") {
                hostHeader = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let target = dnsServer.resolveHTTPTarget(hostHeader: hostHeader),
              let httpPort = target.httpPort, httpPort > 0 else {
            let msg = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nUnknown local domain: \(hostHeader)\n"
            _ = writeAll(fd: clientFD, data: Data(msg.utf8))
            close(clientFD)
            return
        }
        if target.paused, let proj = target.project {
            try? ensureThawed(project: proj, targetContainer: target.containerName)
        }
        lock.lock()
        let mapping = mappingsByPort.values.first {
            $0.containerName == target.containerName && $0.guestPort == httpPort
        }
        lock.unlock()
        let useContainerIP = !target.ip.isEmpty
        let destHost = useContainerIP ? target.ip : "127.0.0.1"
        let destPort = useContainerIP ? UInt16(httpPort) : UInt16(mapping?.hostPort ?? httpPort)
        guard !destHost.isEmpty, destPort > 0 else {
            let msg = "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\nNo reachable target port\n"
            _ = writeAll(fd: clientFD, data: Data(msg.utf8))
            close(clientFD)
            return
        }
        do {
            let vsockConn = try openTunnelWithRetry(host: destHost, port: destPort)
            guard writeAll(fd: vsockConn.fileDescriptor, data: reqBuf) else {
                vsockConn.close()
                close(clientFD)
                return
            }
            spliceBidirectional(fd: clientFD, vsockConn: vsockConn)
        } catch {
            let msg = "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\nTunnel error: \(error.localizedDescription)\n"
            _ = writeAll(fd: clientFD, data: Data(msg.utf8))
            close(clientFD)
        }
    }

    public func stop() {
        running = false
        for fd in httpListenFDs {
            close(fd)
        }
        httpListenFDs.removeAll()
        lock.lock()
        for fds in listeners.values {
            for fd in fds { close(fd) }
        }
        listeners.removeAll()
        lock.unlock()
        topoCond.lock()
        topoCond.broadcast()
        topoCond.unlock()
    }
}
