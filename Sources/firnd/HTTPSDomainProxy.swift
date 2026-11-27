import Darwin
import Foundation
import FirnCore
import Network
import Security
import Virtualization

public final class HTTPSDomainProxy {
    private let autoThaw: AutoThawProxy
    private let dnsServer: LocalDNSServer
    private let domain: String
    private let httpsPort: UInt16
    private let queue = DispatchQueue(label: "dev.firn.https-proxy")

    private let lock = NSLock()
    private let reloadQueue = DispatchQueue(label: "dev.firn.https-proxy.reload")
    private var listenerEntries: [(listener: NWListener, cancelGroup: DispatchGroup)] = []
    private var activeProjects: [String] = []
    private var running = false

    public init(autoThaw: AutoThawProxy, dnsServer: LocalDNSServer, domain: String, httpsPort: UInt16) {
        self.autoThaw = autoThaw
        self.dnsServer = dnsServer
        self.domain = domain
        self.httpsPort = httpsPort
    }

    public func start() throws {
        lock.lock()
        running = true
        lock.unlock()
        try reloadQueue.sync {
            try startListeners(projects: [])
        }
    }

    public func reloadCertificates(projects: [String]) {
        let sorted = projects.sorted()
        reloadQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let unchanged = (sorted == self.activeProjects) && self.running && !self.listenerEntries.isEmpty
            self.lock.unlock()
            if unchanged { return }
            try? self.startListeners(projects: sorted)
        }
    }

    private func startListeners(projects: [String]) throws {
        lock.lock()
        let isRunning = running
        lock.unlock()
        guard isRunning else { return }

        let identity = try CertAuthority.ensureServerIdentity(domain: domain, projects: projects)
        guard let secIdentity = sec_identity_create(identity) else {
            throw NSError(domain: "FirnHTTPS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed wrapping SecIdentity"])
        }
        guard let port = NWEndpoint.Port(rawValue: httpsPort) else {
            throw NSError(domain: "FirnHTTPS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTPS port \(httpsPort)"])
        }

        // Cancel existing listeners first so loopback :8443 is released before rebinding.
        lock.lock()
        let oldEntries = listenerEntries
        listenerEntries.removeAll()
        lock.unlock()
        for entry in oldEntries {
            entry.listener.cancel()
            _ = entry.cancelGroup.wait(timeout: .now() + 2.0)
        }

        let makeParams: (NWEndpoint.Host) -> NWParameters = { host in
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: tls, tcp: tcp)
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: port)
            return params
        }

        var newEntries: [(listener: NWListener, cancelGroup: DispatchGroup)] = []
        for host in [NWEndpoint.Host("127.0.0.1"), NWEndpoint.Host("::1")] {
            if let listener = try? NWListener(using: makeParams(host)) {
                let cancelGroup = DispatchGroup()
                cancelGroup.enter()
                let readyGroup = DispatchGroup()
                readyGroup.enter()
                let stateLock = NSLock()
                var readyDone = false
                var cancelDone = false
                var listenerReady = false

                listener.stateUpdateHandler = { state in
                    stateLock.lock()
                    switch state {
                    case .ready:
                        listenerReady = true
                        if !readyDone {
                            readyDone = true
                            readyGroup.leave()
                        }
                    case .failed:
                        if !readyDone {
                            readyDone = true
                            readyGroup.leave()
                        }
                    case .cancelled:
                        if !readyDone {
                            readyDone = true
                            readyGroup.leave()
                        }
                        if !cancelDone {
                            cancelDone = true
                            cancelGroup.leave()
                        }
                    default:
                        break
                    }
                    stateLock.unlock()
                }
                listener.newConnectionHandler = { [weak self] conn in
                    self?.handleConnection(conn)
                }
                listener.start(queue: queue)
                _ = readyGroup.wait(timeout: .now() + 2.0)
                stateLock.lock()
                let ok = listenerReady
                stateLock.unlock()
                if ok {
                    newEntries.append((listener: listener, cancelGroup: cancelGroup))
                } else {
                    listener.cancel()
                    _ = cancelGroup.wait(timeout: .now() + 1.0)
                }
            }
        }
        guard !newEntries.isEmpty else {
            throw NSError(domain: "FirnHTTPS", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot bind loopback HTTPS port \(httpsPort)"])
        }

        lock.lock()
        listenerEntries = newEntries
        activeProjects = projects
        lock.unlock()
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHTTPHeader(conn, accumulated: Data())
    }

    private func readHTTPHeader(_ conn: NWConnection, accumulated: Data) {
        let delim = Data("\r\n\r\n".utf8)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            if error != nil {
                conn.cancel()
                return
            }
            var buf = accumulated
            if let content, !content.isEmpty {
                buf.append(content)
            }
            if let headerEnd = buf.range(of: delim) {
                self.dispatchTLSHTTP(conn, reqBuf: buf, headerEnd: headerEnd)
                return
            }
            if isComplete || buf.count >= 65536 {
                conn.cancel()
                return
            }
            self.readHTTPHeader(conn, accumulated: buf)
        }
    }

    private func sendHTTPAndClose(_ conn: NWConnection, response: String) {
        conn.send(content: Data(response.utf8), isComplete: true, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func dispatchTLSHTTP(_ conn: NWConnection, reqBuf: Data, headerEnd: Range<Data.Index>) {
        guard let headerStr = String(data: reqBuf[..<headerEnd.lowerBound], encoding: .utf8) else {
            conn.cancel()
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
            sendHTTPAndClose(
                conn,
                response: "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nUnknown local HTTPS domain: \(hostHeader)\n"
            )
            return
        }
        if target.paused, let proj = target.project {
            try? autoThaw.ensureThawed(project: proj, targetContainer: target.containerName)
        }
        let mappings = autoThaw.currentPortMappings()
        let mapping = mappings.first {
            $0.containerName == target.containerName && $0.guestPort == httpPort
        }
        let useContainerIP = !target.ip.isEmpty
        let destHost = useContainerIP ? target.ip : "127.0.0.1"
        let destPort = useContainerIP ? UInt16(httpPort) : UInt16(mapping?.hostPort ?? httpPort)
        guard !destHost.isEmpty, destPort > 0 else {
            sendHTTPAndClose(conn, response: "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\nNo reachable target port\n")
            return
        }

        do {
            let vsockConn = try autoThaw.openTunnelWithRetry(host: destHost, port: destPort)
            let vfd = vsockConn.fileDescriptor
            guard writeAll(fd: vfd, data: reqBuf) else {
                withExtendedLifetime(vsockConn) { vsockConn.close() }
                conn.cancel()
                return
            }
            spliceTLSConnection(conn: conn, vsockConn: vsockConn)
        } catch {
            sendHTTPAndClose(conn, response: "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\nTunnel error: \(error.localizedDescription)\n")
        }
    }

    private func spliceTLSConnection(conn: NWConnection, vsockConn: VZVirtioSocketConnection) {
        let vfd = vsockConn.fileDescriptor
        let closeLock = NSLock()
        var closed = false
        var remainingDirections = 2

        let finishDirection: () -> Void = {
            closeLock.lock()
            remainingDirections -= 1
            let shouldClose = remainingDirections <= 0 && !closed
            if shouldClose { closed = true }
            closeLock.unlock()
            if shouldClose {
                withExtendedLifetime(vsockConn) { vsockConn.close() }
                conn.cancel()
            }
        }

        // Guest vsock -> TLS NWConnection
        spawnIOThread {
            var buf = [UInt8](repeating: 0, count: 262144)
            let sendGroup = DispatchGroup()
            while true {
                let n = buf.withUnsafeMutableBytes { ptr in
                    read(vfd, ptr.baseAddress, ptr.count)
                }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                let chunk = Data(buf[0..<n])
                sendGroup.enter()
                conn.send(content: chunk, completion: .contentProcessed { err in
                    sendGroup.leave()
                    if err != nil {
                        shutdown(vfd, SHUT_RD)
                    }
                })
                sendGroup.wait()
            }
            sendGroup.enter()
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                sendGroup.leave()
            })
            _ = sendGroup.wait(timeout: .now() + 2.0)
            finishDirection()
        }

        // TLS NWConnection -> Guest vsock
        func pumpClientToVsock() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 262144) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    if !writeAll(fd: vfd, data: data) {
                        finishDirection()
                        return
                    }
                }
                if isComplete || error != nil {
                    shutdown(vfd, SHUT_WR)
                    finishDirection()
                    return
                }
                pumpClientToVsock()
            }
        }
        pumpClientToVsock()
    }

    public func stop() {
        lock.lock()
        running = false
        let current = listenerEntries
        listenerEntries.removeAll()
        lock.unlock()
        for entry in current {
            entry.listener.cancel()
            _ = entry.cancelGroup.wait(timeout: .now() + 1.0)
        }
    }
}
