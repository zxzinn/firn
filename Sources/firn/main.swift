import Darwin
import Foundation
import FirnCore

private let firnVersion = "0.3.0"

private func urlEncoded(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?&=#+")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func findRepoRootBinary(_ name: String) -> URL? {
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let sibling = exeDir.appendingPathComponent(name)
    if FileManager.default.isExecutableFile(atPath: sibling.path) {
        return sibling
    }
    let cwdBuild = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build")
        .appendingPathComponent(name)
    if FileManager.default.isExecutableFile(atPath: cwdBuild.path) {
        return cwdBuild
    }
    if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
        for dir in pathEnv.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
    }
    return nil
}

private func findFirnApp() -> URL? {
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    for candidate in [
        exeDir.appendingPathComponent("Firn.app"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Firn.app"),
        URL(fileURLWithPath: "/Applications/Firn.app"),
    ] {
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

@discardableResult
private func runShellCommand(_ executable: String, _ args: [String], capture: Bool = true, inputData: Data? = nil) throws -> (code: Int32, stdout: String, stderr: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    if capture {
        proc.standardOutput = outPipe
        proc.standardError = errPipe
    }
    if let inputData {
        let inPipe = Pipe()
        proc.standardInput = inPipe
        try proc.run()
        inPipe.fileHandleForWriting.write(inputData)
        inPipe.fileHandleForWriting.closeFile()
    } else {
        try proc.run()
    }
    var outData = Data()
    var errData = Data()
    if capture {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
    }
    proc.waitUntilExit()
    let outStr = capture ? (String(data: outData, encoding: .utf8) ?? "") : ""
    let errStr = capture ? (String(data: errData, encoding: .utf8) ?? "") : ""
    return (proc.terminationStatus, outStr, errStr)
}

private func findDockerCLI() -> String {
    for path in ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker"] {
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    return "/usr/bin/env"
}

private func runDocker(_ args: [String], capture: Bool = true) throws -> (code: Int32, stdout: String, stderr: String) {
    let bin = findDockerCLI()
    let finalArgs = bin == "/usr/bin/env" ? ["docker"] + args : args
    return try runShellCommand(bin, finalArgs, capture: capture)
}

private func ensureDockerContext(_ name: String, dockerSock: URL) throws {
    let hostArg = "host=unix://\(dockerSock.path)"
    let inspect = try runDocker(["context", "inspect", name])
    let action = inspect.code == 0 ? "update" : "create"
    let res = try runDocker(["context", action, name, "--docker", hostArg])
    if res.code != 0 {
        throw NSError(domain: "Firn", code: 201, userInfo: [NSLocalizedDescriptionKey: "docker context \(action) failed: \(res.stderr)"])
    }
}

private func u64(_ dict: [String: Any], _ key: String) -> UInt64 {
    (dict[key] as? NSNumber)?.uint64Value ?? 0
}

private func dbl(_ dict: [String: Any], _ key: String) -> Double {
    (dict[key] as? NSNumber)?.doubleValue ?? 0
}

private func padRight(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

private func padLeft(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

private func printStatus(_ statusData: [String: Any]) {
    let vm = (statusData["vmMemory"] as? [String: Any]) ?? [:]
    let balloon = (statusData["balloon"] as? [String: Any]) ?? [:]
    let dns = (statusData["dns"] as? [String: Any]) ?? [:]
    let proxy = (statusData["proxy"] as? [String: Any]) ?? [:]
    let hostMem = (statusData["hostMemory"] as? [String: Any]) ?? [:]
    let disk = (statusData["disk"] as? [String: Any]) ?? [:]

    print(
        "VM Memory: total=\(FirnHostClient.formatBytes(u64(vm, "totalBytes"))) " +
        "available=\(FirnHostClient.formatBytes(u64(vm, "availableBytes"))) " +
        "balloonTarget=\(FirnHostClient.formatBytes(u64(balloon, "targetBytes"))) " +
        "swapUsed=\(FirnHostClient.formatBytes(u64(vm, "swapUsedBytes")))/\(FirnHostClient.formatBytes(u64(vm, "swapTotalBytes")))"
    )
    if !hostMem.isEmpty {
        print(
            "Host Memory: footprint=\(FirnHostClient.formatBytes(u64(hostMem, "footprintBytes"))) " +
            "(firnd=\(FirnHostClient.formatBytes(u64(hostMem, "daemonFootprintBytes"))), " +
            "vm=\(FirnHostClient.formatBytes(u64(hostMem, "vmFootprintBytes")))) " +
            "rss=\(FirnHostClient.formatBytes(u64(hostMem, "rssBytes")))"
        )
    }
    if !disk.isEmpty {
        print(
            "APFS Disk: allocated=\(FirnHostClient.formatBytes(u64(disk, "hostAllocatedBytes"))) / " +
            "logical=\(FirnHostClient.formatBytes(u64(disk, "hostLogicalBytes")))"
        )
    }
    if !dns.isEmpty {
        let dom = (dns["domain"] as? String) ?? "firn.local"
        let caTrusted = (dns["caTrusted"] as? Bool) ?? false
        print(
            "DNS & Proxy: *.\(dom) " +
            "(UDP :\(u64(dns, "dnsPort")), HTTP :\(u64(dns, "httpProxyPort")), HTTPS :\(u64(dns, "httpsProxyPort")), " +
            "caTrusted=\(caTrusted), records=\(u64(dns, "recordCount")), ports=\(u64(statusData, "ports")))"
        )
    }
    if !proxy.isEmpty {
        let vpn = ((proxy["vpnActive"] as? Bool) ?? false) ? "active" : "inactive"
        let hp = (proxy["httpProxy"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "none"
        let relay = (proxy["hostDnsRelay"] as? Bool) ?? true
        let ssh = (proxy["sshAgentActive"] as? Bool) ?? false
        print("Network Relay: vpn=\(vpn), macOS_http_proxy=\(hp), host_dns_relay=\(relay), ssh_agent=\(ssh)")
    }

    let projects = (statusData["projects"] as? [[String: Any]]) ?? []
    if projects.isEmpty {
        print("No containers present.")
        return
    }
    print("\(padRight("PROJECT", 32)) \(padLeft("RUN", 3)) \(padLeft("PAUSED", 6)) \(padRight("EXEMPT", 6)) \(padLeft("IDLE(s)", 8)) \(padLeft("MEM", 10)) \(padLeft("SWAP", 10))")
    for proj in projects {
        let name = (proj["project"] as? String) ?? ""
        let run = "\(u64(proj, "runningCount"))"
        let paused = "\(u64(proj, "pausedCount"))"
        let exempt = ((proj["exempt"] as? Bool) ?? false) ? "true" : "false"
        let idle = String(format: "%.1f", dbl(proj, "idleForSeconds"))
        let mem = FirnHostClient.formatBytes(u64(proj, "memoryBytes"))
        let swap = FirnHostClient.formatBytes(u64(proj, "swapBytes"))
        print("\(padRight(name, 32)) \(padLeft(run, 3)) \(padLeft(paused, 6)) \(padRight(exempt, 6)) \(padLeft(idle, 8)) \(padLeft(mem, 10)) \(padLeft(swap, 10))")
    }
}

private func printPrettyJSON(_ obj: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return
    }
    print(text)
}

private func collectOrbstackMetrics() -> [String: Any]? {
    guard let ps = try? runDocker(["--context", "orbstack", "ps", "--format", "{{.Label \"com.docker.compose.project\"}}"]),
          ps.code == 0 else {
        return nil
    }
    let lines = ps.stdout.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let runningCount = lines.filter { !$0.isEmpty }.count
    let projectCount = Set(lines.filter { !$0.isEmpty }).count

    var helperRSSMiB = 0.0
    var helperCPU = 0.0
    if let procOut = try? runShellCommand("/bin/ps", ["-A", "-o", "rss=,%cpu=,comm="]), procOut.code == 0 {
        for raw in procOut.stdout.split(separator: "\n") {
            let line = String(raw)
            guard line.contains("OrbStack Helper") else { continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2, let kb = Double(parts[0]), let cpu = Double(parts[1]) {
                helperRSSMiB += kb / 1024.0
                helperCPU += cpu
            }
        }
    }
    return [
        "runningContainers": runningCount,
        "composeProjects": projectCount,
        "hostHelperRssMiB": (helperRSSMiB * 10).rounded() / 10,
        "hostHelperCpuPercent": (helperCPU * 10).rounded() / 10,
    ]
}

private func cmdUp(_ args: [String]) throws -> Int32 {
    var cpus: String?
    var memGiB: String?
    var contextName = FirnConfig.defaultDockerContext
    var idx = 0
    while idx < args.count {
        let a = args[idx]
        if a == "--cpus", idx + 1 < args.count { cpus = args[idx + 1]; idx += 2; continue }
        if a == "--memory-gib", idx + 1 < args.count { memGiB = args[idx + 1]; idx += 2; continue }
        if a == "--context", idx + 1 < args.count { contextName = args[idx + 1]; idx += 2; continue }
        throw NSError(domain: "Firn", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown option for `up`: \(a)"])
    }

    let fm = FileManager.default
    for required in [FirnPaths.kernelURL, FirnPaths.initramfsURL, FirnPaths.rootfsURL, FirnPaths.dataDiskURL] {
        if !fm.fileExists(atPath: required.path) {
            throw NSError(domain: "Firn", code: 3, userInfo: [NSLocalizedDescriptionKey: "VM images not built yet (missing \(required.path)); run `make build` first."])
        }
    }
    guard let firndBin = findRepoRootBinary("firnd") else {
        throw NSError(domain: "Firn", code: 4, userInfo: [NSLocalizedDescriptionKey: "firnd binary not found; run `make build` first."])
    }

    if !FirnHostClient.isDaemonAlive() {
        try fm.createDirectory(at: FirnPaths.stateDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: FirnPaths.runDir, withIntermediateDirectories: true)
        fm.createFile(atPath: FirnPaths.daemonLogURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: FirnPaths.daemonLogURL)
        try logHandle.truncate(atOffset: 0)

        var env = ProcessInfo.processInfo.environment
        if let cpus { env["FIRN_CPUS"] = cpus }
        if let memGiB { env["FIRN_MEMORY_GIB"] = memGiB }

        let started = Date()
        let proc = Process()
        proc.executableURL = firndBin
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        try proc.run()

        let deadline = Date().addingTimeInterval(30.0)
        var ready = false
        while Date() < deadline {
            if let health = try? FirnHostClient.requestJSON(method: "GET", path: "/health", timeoutSeconds: 2),
               (health["ok"] as? Bool) == true {
                ready = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if !ready {
            let logTail = (try? String(contentsOf: FirnPaths.daemonLogURL, encoding: .utf8)) ?? ""
            let serial = ((try? String(contentsOf: FirnPaths.serialLogURL, encoding: .utf8)) ?? "").suffix(1500)
            throw NSError(domain: "Firn", code: 5, userInfo: [NSLocalizedDescriptionKey: "firnd did not become ready within 30s.\nLog:\n\(logTail)\nSerial:\n\(serial)"])
        }
        let bootMs = (Date().timeIntervalSince(started) * 1000 * 10).rounded() / 10
        print("[firn] Cold booted Firn VM + dockerd + firn-guestd in \(bootMs) ms")
    }

    try ensureDockerContext(contextName, dockerSock: FirnPaths.dockerSockURL)
    print("[firn] Docker context '\(contextName)' configured (default context preserved).")
    let status = try FirnHostClient.requestJSON(method: "GET", path: "/status")
    printStatus(status)
    return 0
}

private func cmdDown() -> Int32 {
    if FileManager.default.fileExists(atPath: FirnPaths.hostSockURL.path) {
        _ = try? FirnHostClient.requestJSON(method: "POST", path: "/shutdown", timeoutSeconds: 5)
    }
    let deadline = Date().addingTimeInterval(12.0)
    while FirnHostClient.isDaemonAlive() && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if FirnHostClient.isDaemonAlive(), let pid = FirnHostClient.readDaemonPID() {
        _ = kill(pid, SIGKILL)
    }
    print("[firn] stopped.")
    return 0
}

private func cmdShell(_ args: [String]) throws -> Int32 {
    let sockPath = FirnPaths.shellSockURL.path
    guard FileManager.default.fileExists(atPath: sockPath) else {
        throw NSError(domain: "Firn", code: 60, userInfo: [NSLocalizedDescriptionKey: "Shell socket \(sockPath) not found. Run `firn up` first."])
    }

    var cmdArgs = args
    if cmdArgs.first == "--" {
        cmdArgs.removeFirst()
    }
    let interactive = cmdArgs.isEmpty && isatty(STDIN_FILENO) == 1
    let argv: [String]
    if cmdArgs.isEmpty {
        argv = ["/bin/sh", "-l"]
    } else if cmdArgs.count == 1 && cmdArgs[0].contains(" ") {
        argv = ["/bin/sh", "-lc", cmdArgs[0]]
    } else {
        argv = cmdArgs
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(sockPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        throw NSError(domain: "Firn", code: 61, userInfo: [NSLocalizedDescriptionKey: "Socket path too long"])
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

    var ws = winsize()
    if isatty(STDOUT_FILENO) == 1 {
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws)
    }
    let rows = ws.ws_row > 0 ? Int(ws.ws_row) : 24
    let cols = ws.ws_col > 0 ? Int(ws.ws_col) : 80

    let handshakeObj: [String: Any] = [
        "argv": argv,
        "rows": rows,
        "cols": cols,
        "tty": interactive,
    ]
    var handshake = try JSONSerialization.data(withJSONObject: handshakeObj)
    handshake.append(0x0A)
    guard writeAllFD(fd, handshake) else {
        throw NSError(domain: "Firn", code: 62, userInfo: [NSLocalizedDescriptionKey: "Failed writing shell handshake"])
    }

    var savedTerm = termios()
    var didRaw = false
    if interactive {
        if tcgetattr(STDIN_FILENO, &savedTerm) == 0 {
            var raw = savedTerm
            cfmakeraw(&raw)
            if tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 {
                didRaw = true
            }
        }
    }
    defer {
        if didRaw {
            tcsetattr(STDIN_FILENO, TCSANOW, &savedTerm)
        }
    }

    let writeLock = NSLock()
    let sendFrame: (UInt8, Data) -> Bool = { kind, payload in
        var pkt = Data([kind])
        var lenBE = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &lenBE) { pkt.append(contentsOf: $0) }
        if !payload.isEmpty { pkt.append(payload) }
        writeLock.lock()
        let ok = writeAllFD(fd, pkt)
        writeLock.unlock()
        return ok
    }

    var winchSrc: DispatchSourceSignal?
    if interactive {
        signal(SIGWINCH, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        src.setEventHandler {
            var cur = winsize()
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &cur) == 0 {
                var rBE = UInt16(cur.ws_row).bigEndian
                var cBE = UInt16(cur.ws_col).bigEndian
                var body = Data()
                withUnsafeBytes(of: &rBE) { body.append(contentsOf: $0) }
                withUnsafeBytes(of: &cBE) { body.append(contentsOf: $0) }
                _ = sendFrame(0x01, body)
            }
        }
        src.resume()
        winchSrc = src
    }
    defer { winchSrc?.cancel() }

    DispatchQueue.global(qos: .userInteractive).async {
        var inBuf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(STDIN_FILENO, &inBuf, inBuf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 {
                _ = sendFrame(0x03, Data())
                break
            }
            if !sendFrame(0x00, Data(inBuf[0..<n])) {
                break
            }
        }
    }

    var exitCode: Int32 = 0
    while true {
        guard let hdr = readExactFD(fd, count: 5) else { break }
        let kind = hdr[0]
        let len = (UInt32(hdr[1]) << 24) | (UInt32(hdr[2]) << 16) | (UInt32(hdr[3]) << 8) | UInt32(hdr[4])
        let payload = len > 0 ? (readExactFD(fd, count: Int(len)) ?? Data()) : Data()
        if payload.count < Int(len) { break }
        if kind == 0x00 {
            _ = writeAllFD(STDOUT_FILENO, payload)
        } else if kind == 0x02 && payload.count == 4 {
            let rawCode = (UInt32(payload[0]) << 24) | (UInt32(payload[1]) << 16) | (UInt32(payload[2]) << 8) | UInt32(payload[3])
            exitCode = Int32(bitPattern: rawCode)
            break
        }
    }
    return exitCode
}

private func writeAllFD(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return true }
        var off = 0
        while off < raw.count {
            let w = write(fd, base.advanced(by: off), raw.count - off)
            if w < 0 && errno == EINTR { continue }
            if w <= 0 { return false }
            off += w
        }
        return true
    }
}

private func readExactFD(_ fd: Int32, count: Int) -> Data? {
    var out = Data(count: count)
    var off = 0
    while off < count {
        let n = out.withUnsafeMutableBytes { ptr in
            read(fd, ptr.baseAddress!.advanced(by: off), count - off)
        }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return nil }
        off += n
    }
    return out
}

private func cmdBench(_ args: [String]) throws -> Int32 {
    var targetProject: String?
    var compareOrb = false
    var idx = 0
    while idx < args.count {
        let a = args[idx]
        if a == "--project", idx + 1 < args.count { targetProject = args[idx + 1]; idx += 2; continue }
        if a == "--compare-orbstack" { compareOrb = true; idx += 1; continue }
        throw NSError(domain: "Firn", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unknown option for `bench`: \(a)"])
    }

    let before = try FirnHostClient.requestJSON(method: "GET", path: "/status")
    let projects = (before["projects"] as? [[String: Any]]) ?? []
    let chosen: [String: Any]
    if let tp = targetProject {
        guard let found = projects.first(where: { ($0["project"] as? String) == tp }) else {
            throw NSError(domain: "Firn", code: 7, userInfo: [NSLocalizedDescriptionKey: "Project '\(tp)' not found"])
        }
        chosen = found
    } else {
        guard let found = projects.first(where: {
            (($0["hasComposeProject"] as? Bool) ?? false) && !(($0["exempt"] as? Bool) ?? false) && u64($0, "runningCount") > 0
        }) else {
            throw NSError(domain: "Firn", code: 8, userInfo: [NSLocalizedDescriptionKey: "No running non-exempt Compose project found to benchmark; pass --project"])
        }
        chosen = found
    }

    let projName = (chosen["project"] as? String) ?? ""
    let beforeMem = (before["hostMemory"] as? [String: Any]) ?? [:]
    let freezeResult = try FirnHostClient.requestJSON(method: "POST", path: "/freeze/\(urlEncoded(projName))?reclaim=1")
    Thread.sleep(forTimeInterval: 0.3)
    let afterFreeze = try FirnHostClient.requestJSON(method: "GET", path: "/status")
    let afterMem = (afterFreeze["hostMemory"] as? [String: Any]) ?? [:]
    let afterProjects = (afterFreeze["projects"] as? [[String: Any]]) ?? []
    let frozenProj = afterProjects.first(where: { ($0["project"] as? String) == projName }) ?? [:]

    let thawStart = Date()
    let thawResult = try FirnHostClient.requestJSON(method: "POST", path: "/thaw/\(urlEncoded(projName))")
    let hostThawMs = (Date().timeIntervalSince(thawStart) * 1000 * 100).rounded() / 100
    let balloonInfo = (freezeResult["balloon"] as? [String: Any]) ?? [:]

    let toMiB: (UInt64) -> Double = { ((Double($0) / (1024 * 1024)) * 10).rounded() / 10 }
    var report: [String: Any] = [
        "project": projName,
        "beforeMemoryBytes": u64(chosen, "memoryBytes"),
        "afterReclaimMemoryBytes": u64(frozenProj, "memoryBytes"),
        "reclaimedBytes": u64(freezeResult, "totalReclaimedBytes"),
        "swapBytesAfterReclaim": u64(frozenProj, "swapBytes"),
        "balloonBeforeBytes": u64(balloonInfo, "beforeTargetBytes"),
        "balloonAfterBytes": u64(balloonInfo, "afterTargetBytes"),
        "hostFootprintBeforeMiB": toMiB(u64(beforeMem, "footprintBytes")),
        "hostFootprintAfterMiB": toMiB(u64(afterMem, "footprintBytes")),
        "hostRssBeforeMiB": toMiB(u64(beforeMem, "rssBytes")),
        "hostRssAfterMiB": toMiB(u64(afterMem, "rssBytes")),
        "freezeDurationMs": dbl(freezeResult, "durationMs"),
        "guestThawDurationMs": dbl(thawResult, "durationMs"),
        "hostThawRoundtripMs": hostThawMs,
    ]
    if compareOrb, let orb = collectOrbstackMetrics() {
        report["orbstack"] = orb
    }
    printPrettyJSON(report)
    return 0
}

private func cmdDoctor() -> Int32 {
    let fm = FileManager.default
    let cfg = FirnConfig.load()
    var issues = 0

    let hv = (try? runShellCommand("/usr/sbin/sysctl", ["-n", "kern.hv_support"]))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
    print("[\(hv == "1" ? "OK" : "FAIL")] Apple Hypervisor/Virtualization support: \(hv == "1" ? "enabled" : "unavailable")")
    if hv != "1" { issues += 1 }

    let rosetta = fm.fileExists(atPath: "/Library/Apple/usr/libexec/oah/RosettaLinux/rosetta")
    print("[\(rosetta ? "OK" : "INFO")] Rosetta x86_64 Linux runtime: \(rosetta ? "installed" : "not installed (arm64-only mode)")")

    if let firndBin = findRepoRootBinary("firnd") {
        let sign = try? runShellCommand("/usr/bin/codesign", ["-d", "--entitlements", ":-", firndBin.path])
        let hasEnt = (sign?.stdout.contains("com.apple.security.virtualization") == true) || (sign?.stderr.contains("com.apple.security.virtualization") == true)
        print("[\(hasEnt ? "OK" : "FAIL")] firnd binary & virtualization entitlement: \(firndBin.path)")
        if !hasEnt { issues += 1 }
    } else {
        print("[FAIL] firnd binary missing (run `make build`)")
        issues += 1
    }

    let artifacts = [FirnPaths.kernelURL, FirnPaths.initramfsURL, FirnPaths.rootfsURL, FirnPaths.dataDiskURL]
    let allArtifacts = artifacts.allSatisfy { fm.fileExists(atPath: $0.path) }
    print("[\(allArtifacts ? "OK" : "FAIL")] VM state directory (\(FirnPaths.stateDir.path)): \(allArtifacts ? "all disk/kernel images present" : "missing artifacts")")
    if !allArtifacts { issues += 1 }

    if FirnHostClient.isDaemonAlive(),
       let health = try? FirnHostClient.requestJSON(method: "GET", path: "/health", timeoutSeconds: 2),
       (health["ok"] as? Bool) == true {
        print("[OK] firnd daemon & firn-guestd control API: healthy (HTTP :\(cfg.httpProxyPort), HTTPS :\(cfg.httpsProxyPort))")
    } else {
        print("[INFO] firnd daemon: offline (start with `firn up`)")
    }

    let ctxName = FirnConfig.defaultDockerContext
    let ctxCheck = (try? runDocker(["context", "inspect", ctxName]))?.code == 0
    let defaultCtx = (try? runDocker(["context", "show"]))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    print("[\(ctxCheck ? "OK" : "INFO")] Docker context '\(ctxName)': \(ctxCheck ? "configured" : "not registered yet") (current default: \(defaultCtx))")

    let ca = CertAuthority.caTrustStatus()
    print("[\(ca.trusted ? "OK" : "INFO")] Local HTTPS Root CA (\(ca.certPath)): \(ca.exists ? (ca.trusted ? "trusted" : "present (optional: `firn ca install`)") : "generated on first start")")

    let pfInstalled = fm.fileExists(atPath: "/etc/pf.anchors/dev.firn")
    print("[\(pfInstalled ? "OK" : "INFO")] Zero-port HTTPS/HTTP pf anchor (/etc/pf.anchors/dev.firn): \(pfInstalled ? "installed" : "not installed (optional: `firn https install`)")")

    let resolverPath = "/etc/resolver/\(cfg.domain)"
    let hasResolver = fm.fileExists(atPath: resolverPath)
    print("[\(hasResolver ? "OK" : "INFO")] macOS split DNS resolver (\(resolverPath)): \(hasResolver ? "installed" : "not installed (optional: `firn dns install`)")")

    let diskStats = FirnHostClient.hostSparseFileStats()
    if diskStats.logicalBytes > 0 {
        print("[INFO] APFS data disk: \(FirnHostClient.formatBytes(diskStats.allocatedBytes)) allocated / \(FirnHostClient.formatBytes(diskStats.logicalBytes)) logical")
    }

    if let ifc = try? runShellCommand("/sbin/ifconfig", ["-l"]) {
        let count = ifc.stdout.split(whereSeparator: { $0.isWhitespace }).filter { $0.hasPrefix("vmenet") }.count
        print("[INFO] Host vmnet interfaces (vmenet*): \(count) (guest egress bypasses vmnet via firn0 vsock netstack)")
    }

    let hasPlist = fm.fileExists(atPath: FirnPaths.launchAgentURL.path)
    print("[INFO] LaunchAgent autostart (\(FirnLaunchAgent.label)): \(hasPlist ? "installed" : "not installed")")
    return issues == 0 ? 0 : 1
}

private func cmdAutostart(_ action: String) throws -> Int32 {
    let uid = getuid()
    let domainTarget = "gui/\(uid)"
    let serviceTarget = "\(domainTarget)/\(FirnLaunchAgent.label)"
    let plistURL = FirnPaths.launchAgentURL
    switch action {
    case "status":
        let exists = FileManager.default.fileExists(atPath: plistURL.path)
        let loaded = (try? runShellCommand("/bin/launchctl", ["print", serviceTarget]))?.code == 0
        print("LaunchAgent plist: \(exists ? plistURL.path : "not installed")")
        print("launchd service (\(serviceTarget)): \(loaded ? "loaded" : "not loaded")")
        return 0
    case "install":
        guard let firndBin = findRepoRootBinary("firnd") else {
            throw NSError(domain: "Firn", code: 9, userInfo: [NSLocalizedDescriptionKey: "firnd binary not found; build first."])
        }
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = FirnLaunchAgent.plistContents(firndPath: firndBin.path, stateDir: FirnPaths.stateDir)
        try contents.write(to: plistURL, atomically: true, encoding: .utf8)
        _ = try? runShellCommand("/bin/launchctl", ["bootout", serviceTarget])
        let boot = try runShellCommand("/bin/launchctl", ["bootstrap", domainTarget, plistURL.path])
        if boot.code != 0 {
            throw NSError(domain: "Firn", code: 10, userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed: \(boot.stderr)"])
        }
        print("[firn] Installed and loaded LaunchAgent at \(plistURL.path)")
        return 0
    case "uninstall":
        _ = try? runShellCommand("/bin/launchctl", ["bootout", serviceTarget])
        try? FileManager.default.removeItem(at: plistURL)
        print("[firn] Uninstalled LaunchAgent \(FirnLaunchAgent.label)")
        return 0
    default:
        throw NSError(domain: "Firn", code: 11, userInfo: [NSLocalizedDescriptionKey: "Usage: firn autostart <status|install|uninstall>"])
    }
}

private func cmdDNS(_ action: String) throws -> Int32 {
    switch action {
    case "status":
        let res = try FirnHostClient.requestJSON(method: "GET", path: "/dns")
        printPrettyJSON(res)
        return 0
    case "install":
        let st = try FirnHostClient.requestJSON(method: "GET", path: "/status")
        let dns = (st["dns"] as? [String: Any]) ?? [:]
        let domain = (dns["domain"] as? String) ?? FirnConfig.load().domain
        let port = UInt16(u64(dns, "dnsPort") == 0 ? UInt64(FirnConfig.load().dnsPort) : u64(dns, "dnsPort"))
        let content = LocalDNSServer.macOSResolverFileContents(domain: domain, port: port)
        let target = "/etc/resolver/\(domain)"
        let mk = try runShellCommand("/usr/bin/sudo", ["mkdir", "-p", "/etc/resolver"], capture: false)
        if mk.code != 0 { return mk.code }
        let tee = try runShellCommand("/usr/bin/sudo", ["tee", target], capture: true, inputData: Data(content.utf8))
        if tee.code != 0 { return tee.code }
        print("[firn] Installed macOS split resolver at \(target)")
        return 0
    case "uninstall":
        let cfg = FirnConfig.load()
        let target = "/etc/resolver/\(cfg.domain)"
        let rm = try runShellCommand("/usr/bin/sudo", ["rm", "-f", target], capture: false)
        print("[firn] Removed \(target)")
        return rm.code
    default:
        throw NSError(domain: "Firn", code: 12, userInfo: [NSLocalizedDescriptionKey: "Usage: firn dns <status|install|uninstall>"])
    }
}

private func cmdCA(_ action: String) throws -> Int32 {
    switch action {
    case "status":
        _ = try? CertAuthority.ensureCA()
        let st = CertAuthority.caTrustStatus()
        printPrettyJSON([
            "exists": st.exists,
            "trusted": st.trusted,
            "certPath": st.certPath,
            "fingerprint": st.fingerprint,
        ])
        return 0
    case "install":
        let (certURL, _) = try CertAuthority.ensureCA()
        let res = try runShellCommand("/usr/bin/sudo", [
            "/usr/bin/security", "add-trusted-cert", "-d", "-r", "trustRoot",
            "-k", "/Library/Keychains/System.keychain", certURL.path
        ], capture: false)
        if res.code == 0 {
            print("[firn] Trusted Firn Root CA in System Keychain: \(certURL.path)")
        }
        return res.code
    case "uninstall":
        let certURL = FirnPaths.caCertURL
        let res = try runShellCommand("/usr/bin/sudo", [
            "/usr/bin/security", "remove-trusted-cert", "-d", certURL.path
        ], capture: false)
        print("[firn] Removed Firn Root CA trust entry.")
        return res.code
    default:
        throw NSError(domain: "Firn", code: 22, userInfo: [NSLocalizedDescriptionKey: "Usage: firn ca <status|install|uninstall>"])
    }
}

private func cmdHTTPS(_ action: String) throws -> Int32 {
    let cfg = FirnConfig.load()
    let anchorPath = "/etc/pf.anchors/dev.firn"
    switch action {
    case "status":
        let ca = CertAuthority.caTrustStatus()
        let payload: [String: Any]
        if FirnHostClient.isDaemonAlive(),
           let live = try? FirnHostClient.requestJSON(method: "GET", path: "/https", timeoutSeconds: 2) {
            payload = live
        } else {
            payload = [
                "httpsProxyPort": Int(cfg.httpsProxyPort),
                "httpProxyPort": Int(cfg.httpProxyPort),
                "domain": cfg.domain,
                "caExists": ca.exists,
                "caTrusted": ca.trusted,
                "caCertPath": ca.certPath,
                "pfAnchorInstalled": FileManager.default.fileExists(atPath: anchorPath),
                "pfAnchorPath": anchorPath,
            ]
        }
        printPrettyJSON(payload)
        return 0
    case "install":
        let rules = CertAuthority.pfAnchorContents(httpPort: cfg.httpProxyPort, httpsPort: cfg.httpsProxyPort)
        let tee = try runShellCommand("/usr/bin/sudo", ["tee", anchorPath], capture: true, inputData: Data(rules.utf8))
        if tee.code != 0 { return tee.code }
        let load = try runShellCommand("/usr/bin/sudo", ["/sbin/pfctl", "-a", "dev.firn", "-f", anchorPath], capture: false)
        if load.code == 0 {
            _ = try? runShellCommand("/usr/bin/sudo", ["/sbin/pfctl", "-E"], capture: true)
            print("[firn] Installed pf anchor \(anchorPath) (127.0.0.1/::1 :80 -> :\(cfg.httpProxyPort), :443 -> :\(cfg.httpsProxyPort)).")
            print("[firn] Note: add `rdr-anchor \"dev.firn\"` and `load anchor \"dev.firn\" from \"\(anchorPath)\"` to /etc/pf.conf to persist across reboots.")
        }
        return load.code
    case "uninstall":
        _ = try? runShellCommand("/usr/bin/sudo", ["/sbin/pfctl", "-a", "dev.firn", "-F", "all"], capture: true)
        let rm = try runShellCommand("/usr/bin/sudo", ["rm", "-f", anchorPath], capture: false)
        print("[firn] Removed \(anchorPath)")
        return rm.code
    default:
        throw NSError(domain: "Firn", code: 23, userInfo: [NSLocalizedDescriptionKey: "Usage: firn https <status|install|uninstall>"])
    }
}

private func cmdDisk(_ args: [String]) throws -> Int32 {
    let sub = args.first(where: { !$0.hasPrefix("-") }) ?? "usage"
    let jsonMode = args.contains("--json")
    switch sub {
    case "usage":
        if FirnHostClient.isDaemonAlive() {
            let res = try FirnHostClient.requestJSON(method: "GET", path: "/disk/usage")
            if jsonMode {
                printPrettyJSON(res)
                return 0
            }
            print("APFS sparse disk (\(FirnPaths.dataDiskURL.path)): \(FirnHostClient.formatBytes(u64(res, "hostAllocatedBytes"))) allocated / \(FirnHostClient.formatBytes(u64(res, "hostLogicalBytes"))) logical")
            if let guest = res["guest"] as? [String: Any] {
                print("Guest /var/lib/firn: used=\(FirnHostClient.formatBytes(u64(guest, "usedBytes"))), available=\(FirnHostClient.formatBytes(u64(guest, "availableBytes"))), swapfile=\(FirnHostClient.formatBytes(u64(guest, "swapFileBytes"))), zram=\(FirnHostClient.formatBytes(u64(guest, "zramUsedBytes")))/\(FirnHostClient.formatBytes(u64(guest, "zramDiskBytes")))")
            }
            return 0
        }
        let stats = FirnHostClient.hostSparseFileStats()
        if jsonMode {
            printPrettyJSON([
                "hostDiskPath": FirnPaths.dataDiskURL.path,
                "hostLogicalBytes": stats.logicalBytes,
                "hostAllocatedBytes": stats.allocatedBytes,
            ])
        } else {
            print("APFS sparse disk (\(FirnPaths.dataDiskURL.path)): \(FirnHostClient.formatBytes(stats.allocatedBytes)) allocated / \(FirnHostClient.formatBytes(stats.logicalBytes)) logical (VM offline)")
        }
        return 0
    case "trim":
        let res = try FirnHostClient.requestJSON(method: "POST", path: "/disk/trim", timeoutSeconds: 60)
        printPrettyJSON(res)
        return 0
    default:
        throw NSError(domain: "Firn", code: 24, userInfo: [NSLocalizedDescriptionKey: "Usage: firn disk <usage|trim> [--json]"])
    }
}

private func cmdContext(_ action: String) throws -> Int32 {
    let targetCtx = FirnConfig.defaultDockerContext
    let cur = (try? runDocker(["context", "show"]))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
    switch action {
    case "status":
        let savedPrev = (try? String(contentsOf: FirnPaths.prevContextURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        print("Current default context: \(cur)")
        if !savedPrev.isEmpty {
            print("Saved previous context: \(savedPrev)")
        }
        return 0
    case "use":
        try ensureDockerContext(targetCtx, dockerSock: FirnPaths.dockerSockURL)
        if cur != targetCtx && !cur.isEmpty {
            try FileManager.default.createDirectory(at: FirnPaths.stateDir, withIntermediateDirectories: true)
            try cur.write(to: FirnPaths.prevContextURL, atomically: true, encoding: .utf8)
        }
        let res = try runDocker(["context", "use", targetCtx])
        if res.code != 0 {
            throw NSError(domain: "Firn", code: 25, userInfo: [NSLocalizedDescriptionKey: res.stderr])
        }
        print("[firn] Default Docker context set to '\(targetCtx)' (previous: '\(cur)').")
        return 0
    case "restore":
        let saved = (try? String(contentsOf: FirnPaths.prevContextURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let restoreTo = (saved?.isEmpty == false && saved != targetCtx) ? saved! : "default"
        let res = try runDocker(["context", "use", restoreTo])
        if res.code != 0 {
            throw NSError(domain: "Firn", code: 26, userInfo: [NSLocalizedDescriptionKey: res.stderr])
        }
        print("[firn] Restored default Docker context to '\(restoreTo)'.")
        return 0
    default:
        throw NSError(domain: "Firn", code: 27, userInfo: [NSLocalizedDescriptionKey: "Usage: firn context <status|use|restore>"])
    }
}

private func printHelp() {
    print("""
    Firn \(firnVersion) - Native macOS Virtualization.framework Docker runtime

    Usage:
      firn up [--cpus N] [--memory-gib N] [--context NAME]
      firn down
      firn status [--json]
      firn shell [-- COMMAND...]
      firn freeze <project> [--reclaim]
      firn thaw <project>
      firn reclaim [project]
      firn balloon <shrink|reset>
      firn disk <usage|trim> [--json]
      firn dns <status|install|uninstall>
      firn ca <status|install|uninstall>
      firn https <status|install|uninstall>
      firn context <status|use|restore>
      firn proxy
      firn gui
      firn doctor
      firn autostart <status|install|uninstall>
      firn bench [--project NAME] [--compare-orbstack]
      firn logs [--serial|--daemon]
      firn version
    """)
}

private func runCLI() throws -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let cmd = args.first else {
        printHelp()
        return 0
    }
    let rest = Array(args.dropFirst())
    switch cmd {
    case "up":
        return try cmdUp(rest)
    case "down":
        return cmdDown()
    case "status":
        let res = try FirnHostClient.requestJSON(method: "GET", path: "/status")
        if rest.contains("--json") {
            printPrettyJSON(res)
        } else {
            printStatus(res)
        }
        return 0
    case "shell":
        return try cmdShell(rest)
    case "freeze":
        guard let proj = rest.first(where: { !$0.hasPrefix("-") }) else {
            throw NSError(domain: "Firn", code: 13, userInfo: [NSLocalizedDescriptionKey: "Usage: firn freeze <project> [--reclaim]"])
        }
        let query = rest.contains("--reclaim") ? "?reclaim=1" : ""
        let res = try FirnHostClient.requestJSON(method: "POST", path: "/freeze/\(urlEncoded(proj))\(query)")
        printPrettyJSON(res)
        return 0
    case "thaw":
        guard let proj = rest.first else {
            throw NSError(domain: "Firn", code: 14, userInfo: [NSLocalizedDescriptionKey: "Usage: firn thaw <project>"])
        }
        let res = try FirnHostClient.requestJSON(method: "POST", path: "/thaw/\(urlEncoded(proj))")
        printPrettyJSON(res)
        return 0
    case "reclaim":
        let path = rest.first.map { "/reclaim/\(urlEncoded($0))" } ?? "/reclaim"
        let res = try FirnHostClient.requestJSON(method: "POST", path: path)
        printPrettyJSON(res)
        return 0
    case "balloon":
        guard let action = rest.first, action == "shrink" || action == "reset" else {
            throw NSError(domain: "Firn", code: 15, userInfo: [NSLocalizedDescriptionKey: "Usage: firn balloon <shrink|reset>"])
        }
        let res = try FirnHostClient.requestJSON(method: "POST", path: "/balloon/\(action)")
        printPrettyJSON(res)
        return 0
    case "disk":
        return try cmdDisk(rest)
    case "dns":
        return try cmdDNS(rest.first ?? "status")
    case "ca":
        return try cmdCA(rest.first ?? "status")
    case "https":
        return try cmdHTTPS(rest.first ?? "status")
    case "context":
        return try cmdContext(rest.first ?? "status")
    case "proxy":
        let res = try FirnHostClient.requestJSON(method: "GET", path: "/proxy")
        printPrettyJSON(res)
        return 0
    case "gui":
        guard let app = findFirnApp() else {
            throw NSError(domain: "Firn", code: 16, userInfo: [NSLocalizedDescriptionKey: "Firn.app not found; run `make build` first."])
        }
        let rc = try runShellCommand("/usr/bin/open", [app.path], capture: false)
        return rc.code
    case "doctor":
        return cmdDoctor()
    case "autostart":
        return try cmdAutostart(rest.first ?? "status")
    case "bench":
        return try cmdBench(rest)
    case "logs":
        let url = rest.contains("--daemon") ? FirnPaths.daemonLogURL : FirnPaths.serialLogURL
        let txt = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = txt.split(separator: "\n", omittingEmptySubsequences: false).suffix(80)
        print(lines.joined(separator: "\n"))
        return 0
    case "version", "--version", "-v":
        print("Firn \(firnVersion)")
        return 0
    case "help", "--help", "-h":
        printHelp()
        return 0
    default:
        throw NSError(domain: "Firn", code: 17, userInfo: [NSLocalizedDescriptionKey: "Unknown command '\(cmd)'. Run `firn help`."])
    }
}

do {
    exit(try runCLI())
} catch {
    fputs("[firn] \(error.localizedDescription)\n", stderr)
    exit(1)
}
