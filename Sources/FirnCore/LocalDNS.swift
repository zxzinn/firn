import Darwin
import Foundation

public struct DNSRecordEntry: Codable, Sendable {
    public var names: [String]
    public var containerName: String
    public var project: String?
    public var service: String
    public var ip: String
    public var httpPort: Int?
    public var paused: Bool
}

public enum WireDNS {
    public static func parseQuestion(_ packet: Data) -> (name: String, qtype: UInt16, qclass: UInt16, endOffset: Int)? {
        guard packet.count >= 12 else { return nil }
        let qdcount = (UInt16(packet[4]) << 8) | UInt16(packet[5])
        guard qdcount >= 1 else { return nil }
        var idx = 12
        var labels: [String] = []
        while idx < packet.count {
            let len = Int(packet[idx])
            idx += 1
            if len == 0 {
                break
            }
            if (len & 0xC0) != 0 || idx + len > packet.count {
                return nil
            }
            if let label = String(data: packet[idx..<(idx + len)], encoding: .utf8) {
                labels.append(label)
            }
            idx += len
        }
        guard idx + 4 <= packet.count else { return nil }
        let qtype = (UInt16(packet[idx]) << 8) | UInt16(packet[idx + 1])
        let qclass = (UInt16(packet[idx + 2]) << 8) | UInt16(packet[idx + 3])
        return (labels.joined(separator: "."), qtype, qclass, idx + 4)
    }

    public static func buildLocalResponse(for query: Data, domain: String, knownNames: Set<String>, directIPv4: String? = nil) -> Data? {
        guard let question = parseQuestion(query) else { return nil }
        let cleanDomain = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let qname = question.name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let isLocal = qname == cleanDomain || qname.hasSuffix("." + cleanDomain) || knownNames.contains(qname)
        guard isLocal else { return nil }

        var response = Data(query[0..<question.endOffset])
        // Standard response, recursion desired + recursion available, RCODE=0
        response[2] = 0x81
        response[3] = 0x80
        response[6] = 0x00
        response[7] = 0x00
        response[8] = 0x00
        response[9] = 0x00
        response[10] = 0x00
        response[11] = 0x00

        var ipv4Octets: [UInt8] = [127, 0, 0, 1]
        var usingDirectIP = false
        if let directIPv4, !directIPv4.isEmpty {
            var in4 = in_addr()
            if inet_pton(AF_INET, directIPv4, &in4) == 1 {
                let raw = withUnsafeBytes(of: &in4) { Array($0) }
                if raw.count == 4 {
                    ipv4Octets = raw
                    usingDirectIP = true
                }
            }
        }

        if question.qtype == 1 { // A -> container IP (when utun active) or 127.0.0.1
            response[7] = 0x01
            response.append(contentsOf: [
                0xC0, 0x0C,
                0x00, 0x01,
                0x00, 0x01,
                0x00, 0x00, 0x00, 0x05,
                0x00, 0x04
            ] + ipv4Octets)
        } else if question.qtype == 28 && !usingDirectIP { // AAAA -> ::1 (loopback proxy mode)
            response[7] = 0x01
            response.append(contentsOf: [
                0xC0, 0x0C,
                0x00, 0x1C,
                0x00, 0x01,
                0x00, 0x00, 0x00, 0x05,
                0x00, 0x10,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
            ])
        }
        return response
    }

    public static func buildNXDomain(for query: Data) -> Data {
        guard query.count >= 12 else { return Data() }
        var response = query
        response[2] = 0x81
        response[3] = 0x83
        response[7] = 0x00
        return response
    }
}

public final class LocalDNSServer {
    private let port: UInt16
    private let domain: String
    private let lock = NSLock()
    private var records: [DNSRecordEntry] = []
    private var directRouteEnabled = false
    private var sockFD: Int32 = -1
    private var running = false

    public init(port: UInt16, domain: String) {
        self.port = port
        self.domain = domain
    }

    public func setDirectRouteEnabled(_ enabled: Bool) {
        lock.lock()
        directRouteEnabled = enabled
        lock.unlock()
    }

    public func isDirectRouteEnabled() -> Bool {
        lock.lock()
        let v = directRouteEnabled
        lock.unlock()
        return v
    }

    public func updateRecords(_ items: [DNSRecordEntry]) {
        lock.lock()
        records = items
        lock.unlock()
    }

    public func currentRecords() -> [DNSRecordEntry] {
        lock.lock()
        let copy = records
        lock.unlock()
        return copy
    }

    public func resolveHTTPTarget(hostHeader: String) -> DNSRecordEntry? {
        let host = hostHeader.split(separator: ":").first.map { String($0).lowercased() } ?? ""
        guard !host.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return records.first { rec in
            rec.names.contains { $0.lowercased() == host }
        }
    }

    public func start() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        sockFD = fd
        running = true
        Thread.detachNewThread { [weak self] in
            self?.serveLoop(fd: fd)
        }
    }

    private func serveLoop(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while running {
            var peer = sockaddr_storage()
            var peerLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &peerLen)
                }
            }
            if n <= 0 {
                if errno == EINTR { continue }
                break
            }
            let pkt = Data(buffer[0..<n])
            lock.lock()
            let known = Set(records.flatMap { $0.names.map { $0.lowercased() } })
            var directIP: String?
            if directRouteEnabled, let q = WireDNS.parseQuestion(pkt) {
                let qn = q.name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                if let match = records.first(where: { rec in rec.names.contains { $0.lowercased() == qn } }),
                   !match.ip.isEmpty {
                    directIP = match.ip
                }
            }
            lock.unlock()
            let reply = WireDNS.buildLocalResponse(for: pkt, domain: domain, knownNames: known, directIPv4: directIP)
                ?? WireDNS.buildNXDomain(for: pkt)
            guard !reply.isEmpty else { continue }
            _ = reply.withUnsafeBytes { rawBuf in
                withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, rawBuf.baseAddress, reply.count, 0, $0, peerLen)
                    }
                }
            }
        }
    }

    public func stop() {
        running = false
        if sockFD >= 0 {
            close(sockFD)
            sockFD = -1
        }
    }

    public static func macOSResolverFileContents(domain: String, port: UInt16) -> String {
        "# Generated by Firn for *.\(domain)\nnameserver 127.0.0.1\nport \(port)\n"
    }
}
