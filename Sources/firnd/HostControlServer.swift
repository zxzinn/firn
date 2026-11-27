import Darwin
import Foundation
import FirnCore

public final class HostControlServer {
    private let runner: VZMachineRunner
    private let bridge: VsockBridge
    private let balloon: BalloonController
    private let autoThaw: AutoThawProxy
    private let httpsProxy: HTTPSDomainProxy
    private let dnsServer: LocalDNSServer
    private let onShutdownRequested: () -> Void

    private var listenFD: Int32 = -1
    private var running = false
    private let stateLock = NSLock()
    private var lastProxyState = HostProxyState()
    private var liveConfig: FirnConfig

    public init(
        runner: VZMachineRunner,
        bridge: VsockBridge,
        balloon: BalloonController,
        autoThaw: AutoThawProxy,
        httpsProxy: HTTPSDomainProxy,
        dnsServer: LocalDNSServer,
        onShutdownRequested: @escaping () -> Void
    ) {
        self.runner = runner
        self.bridge = bridge
        self.balloon = balloon
        self.autoThaw = autoThaw
        self.httpsProxy = httpsProxy
        self.dnsServer = dnsServer
        self.liveConfig = runner.config
        self.onShutdownRequested = onShutdownRequested
    }

    public func updateProxyState(_ state: HostProxyState) {
        stateLock.lock()
        lastProxyState = state
        stateLock.unlock()
    }

    public func start() throws {
        listenFD = try bindUnixSocket(at: FirnPaths.hostSockURL)
        running = true
        spawnIOThread { [weak self] in
            while self?.running == true {
                guard let self else { break }
                let fd = accept(self.listenFD, nil, nil)
                if fd < 0 {
                    if errno == EINTR { continue }
                    break
                }
                spawnIOThread {
                    self.handleClient(fd)
                }
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 16384)
        var raw = Data()
        let delim = Data("\r\n\r\n".utf8)
        while raw.count < 65536 {
            let n = read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            raw.append(buf, count: n)
            if raw.range(of: delim) != nil { break }
        }
        guard let end = raw.range(of: delim),
              let headerStr = String(data: raw[..<end.lowerBound], encoding: .utf8),
              let reqLine = headerStr.components(separatedBy: "\r\n").first else {
            return
        }
        var contentLength = 0
        for line in headerStr.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
                break
            }
        }
        var bodyData = Data(raw[end.upperBound...])
        while bodyData.count < contentLength && bodyData.count < 1024 * 1024 {
            let n = read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            bodyData.append(buf, count: n)
        }
        if contentLength > 0 && bodyData.count > contentLength {
            bodyData = Data(bodyData.prefix(contentLength))
        }

        let parts = reqLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let fullTarget = String(parts[1])
        let pathOnly = fullTarget.split(separator: "?").first.map(String.init) ?? fullTarget

        let (code, body) = route(method: method, fullTarget: fullTarget, path: pathOnly, body: bodyData)
        let header = "HTTP/1.1 \(code) OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        _ = writeAll(fd: fd, data: Data(header.utf8) + body)
    }

    private func jsonResponse(_ obj: Any, status: Int = 200) -> (Int, Data) {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return (status, data)
    }

    private func queryValue(_ name: String, in fullTarget: String) -> String? {
        guard let comps = URLComponents(string: fullTarget),
              let item = comps.queryItems?.first(where: { $0.name == name }) else {
            return nil
        }
        return item.value
    }

    private func route(method: String, fullTarget: String, path: String, body: Data) -> (Int, Data) {
        if path == "/health" {
            let ok = (try? bridge.guestHTTP(method: "GET", path: "/health"))?.status == 200
            return jsonResponse(["ok": ok], status: ok ? 200 : 503)
        }
        if path == "/status" {
            do {
                let (_, raw) = try bridge.guestHTTP(method: "GET", path: "/status")
                guard var dict = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
                    return (500, raw)
                }
                stateLock.lock()
                let proxy = lastProxyState
                let cfg = liveConfig
                stateLock.unlock()
                let hostMem = HostProcessMetrics.current(daemonPID: getpid())
                let caStatus = CertAuthority.caTrustStatus()
                let diskHost = FirnHostClient.hostSparseFileStats()
                dict["hostMemory"] = [
                    "footprintBytes": hostMem.footprintBytes,
                    "rssBytes": hostMem.rssBytes,
                    "daemonFootprintBytes": hostMem.daemonFootprintBytes,
                    "vmFootprintBytes": hostMem.vmFootprintBytes,
                ]
                dict["balloon"] = [
                    "targetBytes": runner.getBalloonTargetBytes(),
                    "minBytes": runner.config.minBalloonBytes,
                    "maxBytes": runner.config.maxMemoryBytes,
                ]
                dict["dns"] = [
                    "domain": cfg.domain,
                    "dnsPort": Int(cfg.dnsPort),
                    "httpProxyPort": Int(cfg.httpProxyPort),
                    "httpsProxyPort": Int(cfg.httpsProxyPort),
                    "recordCount": dnsServer.currentRecords().count,
                    "caTrusted": caStatus.trusted,
                    "pfRedirectActive": FileManager.default.fileExists(atPath: "/etc/pf.anchors/dev.firn"),
                ]
                dict["proxy"] = [
                    "httpProxy": proxy.httpProxy,
                    "httpsProxy": proxy.httpsProxy,
                    "noProxy": proxy.noProxy,
                    "vpnActive": proxy.vpnActive,
                    "hostDnsRelay": proxy.hostDnsRelay,
                    "sshAgentActive": !(ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? "").isEmpty,
                ]
                dict["disk"] = [
                    "hostLogicalBytes": diskHost.logicalBytes,
                    "hostAllocatedBytes": diskHost.allocatedBytes,
                ]
                dict["ports"] = autoThaw.currentPortMappings().count
                dict["topologyVersion"] = autoThaw.currentTopologyVersion()
                return jsonResponse(dict)
            } catch {
                return jsonResponse(["error": error.localizedDescription], status: 500)
            }
        }
        if path == "/events" {
            let since = UInt64(queryValue("since", in: fullTarget) ?? "0") ?? 0
            let waitSec = Double(queryValue("wait", in: fullTarget) ?? "10") ?? 10.0
            let nextVersion = autoThaw.waitForTopologyChange(since: since, timeoutSeconds: waitSec)
            return jsonResponse(["version": nextVersion])
        }
        if path == "/dns" {
            if let data = try? JSONEncoder().encode(["records": dnsServer.currentRecords()]) {
                return (200, data)
            }
            return jsonResponse(["records": []])
        }
        if path == "/https" {
            let ca = CertAuthority.caTrustStatus()
            return jsonResponse([
                "httpsProxyPort": Int(runner.config.httpsProxyPort),
                "httpProxyPort": Int(runner.config.httpProxyPort),
                "domain": runner.config.domain,
                "caExists": ca.exists,
                "caTrusted": ca.trusted,
                "caCertPath": ca.certPath,
                "fingerprint": ca.fingerprint,
                "pfAnchorInstalled": FileManager.default.fileExists(atPath: "/etc/pf.anchors/dev.firn"),
                "pfAnchorPath": "/etc/pf.anchors/dev.firn",
            ])
        }
        if path == "/proxy" {
            stateLock.lock()
            let proxy = lastProxyState
            stateLock.unlock()
            return jsonResponse([
                "httpProxy": proxy.httpProxy,
                "httpsProxy": proxy.httpsProxy,
                "noProxy": proxy.noProxy,
                "vpnActive": proxy.vpnActive,
                "hostDnsRelay": proxy.hostDnsRelay,
                "sshAgentHost": ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? "",
            ])
        }
        if path == "/disk/usage" {
            let hostStats = FirnHostClient.hostSparseFileStats()
            var out: [String: Any] = [
                "hostDiskPath": FirnPaths.dataDiskURL.path,
                "hostLogicalBytes": hostStats.logicalBytes,
                "hostAllocatedBytes": hostStats.allocatedBytes,
            ]
            if let (_, raw) = try? bridge.guestHTTP(method: "GET", path: "/disk/usage", timeoutSeconds: 5.0),
               let guest = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                out["guest"] = guest
            }
            return jsonResponse(out)
        }
        if method == "POST" && path == "/disk/trim" {
            let before = FirnHostClient.hostSparseFileStats()
            do {
                let (code, raw) = try bridge.guestHTTP(method: "POST", path: "/disk/trim", timeoutSeconds: 60.0)
                let after = FirnHostClient.hostSparseFileStats()
                if var dict = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
                    dict["hostAllocatedBeforeBytes"] = before.allocatedBytes
                    dict["hostAllocatedAfterBytes"] = after.allocatedBytes
                    dict["hostLogicalBytes"] = after.logicalBytes
                    return jsonResponse(dict, status: code)
                }
                return (code, raw)
            } catch {
                return jsonResponse(["error": error.localizedDescription], status: 500)
            }
        }
        if path == "/config" {
            if method == "GET" {
                stateLock.lock()
                let cfg = liveConfig
                stateLock.unlock()
                let data = (try? JSONEncoder().encode(cfg)) ?? Data("{}".utf8)
                return (200, data)
            }
            if method == "POST" {
                guard let req = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                    return jsonResponse(["error": "Invalid JSON config payload"], status: 400)
                }
                stateLock.lock()
                var next = liveConfig
                let prev = liveConfig
                if let cpus = (req["cpus"] as? NSNumber)?.intValue, cpus > 0 { next.cpus = cpus }
                if let mem = (req["memoryGiB"] as? NSNumber)?.intValue, mem > 0 { next.memoryGiB = mem }
                if let minB = (req["minBalloonMiB"] as? NSNumber)?.intValue, minB >= 256 { next.minBalloonMiB = minB }
                if let idle = (req["idleSeconds"] as? NSNumber)?.intValue, idle >= 0 { next.idleSeconds = idle }
                if let dom = req["domain"] as? String, !dom.isEmpty { next.domain = dom }
                if let exempt = req["exemptProjects"] as? [String] { next.exemptProjects = exempt }
                liveConfig = next
                stateLock.unlock()

                do {
                    try next.save()
                } catch {
                    return jsonResponse(["error": error.localizedDescription], status: 500)
                }
                let guestPayload: [String: Any] = [
                    "idleSeconds": next.idleSeconds,
                    "domain": next.domain,
                    "exemptProjects": next.exemptProjects,
                ]
                if let guestBody = try? JSONSerialization.data(withJSONObject: guestPayload) {
                    _ = try? bridge.guestHTTP(method: "POST", path: "/config", body: guestBody, timeoutSeconds: 5.0)
                }
                autoThaw.syncTopologyNow()
                let restartNeeded = (prev.cpus != next.cpus || prev.memoryGiB != next.memoryGiB || prev.domain != next.domain)
                if let cfgObj = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(next))) as? [String: Any] {
                    var resp = cfgObj
                    resp["restartRequired"] = restartNeeded
                    return jsonResponse(resp)
                }
                return jsonResponse(["ok": true, "restartRequired": restartNeeded])
            }
        }
        if method == "POST" && path.hasPrefix("/freeze/") {
            do {
                let (code, raw) = try bridge.guestHTTP(method: "POST", path: fullTarget)
                let shrinkInfo = (fullTarget.contains("reclaim=1") || fullTarget.contains("reclaim=true")) ? balloon.shrinkToGuestDemand() : [:]
                autoThaw.syncTopologyNow()
                if var dict = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
                    dict["balloon"] = shrinkInfo
                    return jsonResponse(dict, status: code)
                }
                return (code, raw)
            } catch {
                return jsonResponse(["error": error.localizedDescription], status: 500)
            }
        }
        if method == "POST" && path.hasPrefix("/thaw/") {
            let proj = path.replacingOccurrences(of: "/thaw/", with: "").removingPercentEncoding ?? ""
            let target = queryValue("target", in: fullTarget)
            let started = Date()
            do {
                try autoThaw.ensureThawed(project: proj, targetContainer: target)
                let ms = (Date().timeIntervalSince(started) * 1000 * 100).rounded() / 100
                return jsonResponse(["project": proj, "durationMs": ms, "balloonTargetBytes": runner.getBalloonTargetBytes()])
            } catch {
                return jsonResponse(["error": error.localizedDescription], status: 500)
            }
        }
        if method == "POST" && (path == "/reclaim" || path.hasPrefix("/reclaim/")) {
            do {
                let (code, raw) = try bridge.guestHTTP(method: "POST", path: fullTarget)
                let shrinkInfo = balloon.shrinkToGuestDemand()
                if var dict = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
                    dict["balloon"] = shrinkInfo
                    return jsonResponse(dict, status: code)
                }
                return (code, raw)
            } catch {
                return jsonResponse(["error": error.localizedDescription], status: 500)
            }
        }
        if method == "POST" && path == "/balloon/shrink" {
            return jsonResponse(balloon.shrinkToGuestDemand())
        }
        if method == "POST" && path == "/balloon/reset" {
            return jsonResponse(balloon.resetBalloon())
        }
        if method == "POST" && path == "/shutdown" {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.onShutdownRequested()
            }
            return jsonResponse(["shuttingDown": true])
        }
        return jsonResponse(["error": "Unknown route: \(path)"], status: 404)
    }

    public func stop() {
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(FirnPaths.hostSockURL.path)
    }
}
