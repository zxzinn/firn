import Foundation

public struct FirnConfig: Codable, Sendable, Equatable {
    public var cpus: Int
    public var memoryGiB: Int
    public var minBalloonMiB: Int
    public var domain: String
    public var dnsPort: UInt16
    public var httpProxyPort: UInt16
    public var httpsProxyPort: UInt16
    public var idleSeconds: Int
    public var exemptProjects: [String]
    public var diskSyncMode: String
    public var fsMode: String
    public var nestedVirtualization: Bool
    public var hibernateSeconds: Int
    public var backend: String
    public var gpu: Bool
    public var directRouteDNS: Bool

    public init(
        cpus: Int = 8,
        memoryGiB: Int = 8,
        minBalloonMiB: Int = 768,
        domain: String = "firn.local",
        dnsPort: UInt16 = 53535,
        httpProxyPort: UInt16 = 8088,
        httpsProxyPort: UInt16 = 8443,
        idleSeconds: Int = 900,
        exemptProjects: [String] = [],
        diskSyncMode: String = "none",
        fsMode: String = "firnfs",
        nestedVirtualization: Bool = false,
        hibernateSeconds: Int = 0,
        backend: String = "vz",
        gpu: Bool = false,
        directRouteDNS: Bool = false
    ) {
        self.cpus = cpus
        self.memoryGiB = memoryGiB
        self.minBalloonMiB = minBalloonMiB
        self.domain = domain
        self.dnsPort = dnsPort
        self.httpProxyPort = httpProxyPort
        self.httpsProxyPort = httpsProxyPort
        self.idleSeconds = idleSeconds
        self.exemptProjects = exemptProjects
        self.diskSyncMode = diskSyncMode
        self.fsMode = fsMode
        self.nestedVirtualization = nestedVirtualization
        self.hibernateSeconds = hibernateSeconds
        self.backend = backend
        self.gpu = gpu
        self.directRouteDNS = directRouteDNS
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FirnConfig()
        self.cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? d.cpus
        self.memoryGiB = try c.decodeIfPresent(Int.self, forKey: .memoryGiB) ?? d.memoryGiB
        self.minBalloonMiB = try c.decodeIfPresent(Int.self, forKey: .minBalloonMiB) ?? d.minBalloonMiB
        self.domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? d.domain
        self.dnsPort = try c.decodeIfPresent(UInt16.self, forKey: .dnsPort) ?? d.dnsPort
        self.httpProxyPort = try c.decodeIfPresent(UInt16.self, forKey: .httpProxyPort) ?? d.httpProxyPort
        self.httpsProxyPort = try c.decodeIfPresent(UInt16.self, forKey: .httpsProxyPort) ?? d.httpsProxyPort
        self.idleSeconds = try c.decodeIfPresent(Int.self, forKey: .idleSeconds) ?? d.idleSeconds
        self.exemptProjects = try c.decodeIfPresent([String].self, forKey: .exemptProjects) ?? d.exemptProjects
        self.diskSyncMode = try c.decodeIfPresent(String.self, forKey: .diskSyncMode) ?? d.diskSyncMode
        self.fsMode = try c.decodeIfPresent(String.self, forKey: .fsMode) ?? d.fsMode
        self.nestedVirtualization = try c.decodeIfPresent(Bool.self, forKey: .nestedVirtualization) ?? d.nestedVirtualization
        self.hibernateSeconds = try c.decodeIfPresent(Int.self, forKey: .hibernateSeconds) ?? d.hibernateSeconds
        self.backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? d.backend
        self.gpu = try c.decodeIfPresent(Bool.self, forKey: .gpu) ?? d.gpu
        self.directRouteDNS = try c.decodeIfPresent(Bool.self, forKey: .directRouteDNS) ?? d.directRouteDNS
    }

    public static var defaultDockerContext: String {
        if let custom = ProcessInfo.processInfo.environment["FIRN_CONTEXT"], !custom.isEmpty {
            return custom
        }
        return "firn"
    }

    private static func parseEnvBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    public static func load(from directory: URL = FirnPaths.stateDir) -> FirnConfig {
        let env = ProcessInfo.processInfo.environment
        var cfg = FirnConfig()
        let configFile = directory.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configFile),
           let decoded = try? JSONDecoder().decode(FirnConfig.self, from: data) {
            cfg = decoded
        }
        if let raw = env["FIRN_CPUS"], let val = Int(raw), val > 0 { cfg.cpus = val }
        if let raw = env["FIRN_MEMORY_GIB"], let val = Int(raw), val > 0 { cfg.memoryGiB = val }
        if let raw = env["FIRN_MIN_BALLOON_MIB"], let val = Int(raw), val >= 256 { cfg.minBalloonMiB = val }
        if let raw = env["FIRN_DOMAIN"], !raw.isEmpty { cfg.domain = raw }
        if let raw = env["FIRN_DNS_PORT"], let val = UInt16(raw), val > 0 { cfg.dnsPort = val }
        if let raw = env["FIRN_HTTP_PROXY_PORT"], let val = UInt16(raw), val > 0 { cfg.httpProxyPort = val }
        if let raw = env["FIRN_HTTPS_PROXY_PORT"], let val = UInt16(raw), val > 0 { cfg.httpsProxyPort = val }
        if let raw = env["FIRN_IDLE_SECONDS"], let val = Int(raw), val >= 0 { cfg.idleSeconds = val }
        if let raw = env["FIRN_EXEMPT_PROJECTS"] {
            cfg.exemptProjects = raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let raw = env["FIRN_DISK_SYNC"], raw == "none" || raw == "fsync" { cfg.diskSyncMode = raw }
        if let raw = env["FIRN_FS_MODE"], raw == "firnfs" || raw == "virtiofs" { cfg.fsMode = raw }
        if let raw = env["FIRN_NESTED_VIRT"], let b = parseEnvBool(raw) { cfg.nestedVirtualization = b }
        if let raw = env["FIRN_HIBERNATE_SECONDS"], let val = Int(raw), val >= 0 { cfg.hibernateSeconds = val }
        if let raw = env["FIRN_BACKEND"], raw == "vz" || raw == "krun" { cfg.backend = raw }
        if let raw = env["FIRN_GPU"], let b = parseEnvBool(raw) { cfg.gpu = b }
        if let raw = env["FIRN_DIRECT_ROUTE_DNS"], let b = parseEnvBool(raw) { cfg.directRouteDNS = b }
        return cfg
    }

    public func save(to directory: URL = FirnPaths.stateDir) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let file = directory.appendingPathComponent("config.json")
        try data.write(to: file, options: .atomic)
    }

    public var maxMemoryBytes: UInt64 {
        UInt64(memoryGiB) * 1024 * 1024 * 1024
    }

    public var minBalloonBytes: UInt64 {
        UInt64(minBalloonMiB) * 1024 * 1024
    }
}

public enum FirnPaths {
    public static var stateDir: URL {
        if let custom = ProcessInfo.processInfo.environment["FIRN_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".firn")
    }

    public static var imagesDir: URL { stateDir.appendingPathComponent("images") }
    public static var runDir: URL { stateDir.appendingPathComponent("run") }
    public static var certsDir: URL { stateDir.appendingPathComponent("certs") }
    public static var leafDirURL: URL { certsDir.appendingPathComponent("leaves") }
    public static var caCertURL: URL { certsDir.appendingPathComponent("ca.crt") }
    public static var caKeyURL: URL { certsDir.appendingPathComponent("ca.key") }
    public static var kernelURL: URL { imagesDir.appendingPathComponent("vmlinux.Image") }
    public static var initramfsURL: URL { imagesDir.appendingPathComponent("initramfs.img") }
    public static var rootfsURL: URL { imagesDir.appendingPathComponent("rootfs.ext4") }
    public static var imageVersionURL: URL { imagesDir.appendingPathComponent("version.txt") }
    public static var dataDiskURL: URL { stateDir.appendingPathComponent("data.ext4") }
    public static var machineIdURL: URL { stateDir.appendingPathComponent("machine-id.bin") }
    public static var vmStateURL: URL { stateDir.appendingPathComponent("vm-state.vzvmsave") }
    public static var dockerSockURL: URL { runDir.appendingPathComponent("docker.sock") }
    public static var hostSockURL: URL { runDir.appendingPathComponent("firnd.sock") }
    public static var shellSockURL: URL { runDir.appendingPathComponent("shell.sock") }
    public static var vmnetFDSockURL: URL { runDir.appendingPathComponent("vmnet-fd.sock") }
    public static var firnfsSockURL: URL { runDir.appendingPathComponent("firnfs.sock") }
    public static var hostnetSockURL: URL { runDir.appendingPathComponent("hostnet.sock") }
    public static var utunSockURL: URL { runDir.appendingPathComponent("utun.sock") }
    public static var pidFileURL: URL { runDir.appendingPathComponent("firnd.pid") }
    public static var prevContextURL: URL { stateDir.appendingPathComponent("prev-context") }
    public static var daemonLogURL: URL { stateDir.appendingPathComponent("firnd.log") }
    public static var hostnetLogURL: URL { stateDir.appendingPathComponent("firn-hostnet.log") }
    public static var serialLogURL: URL { stateDir.appendingPathComponent("serial.log") }
    public static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(FirnLaunchAgent.label).plist")
    }
    public static var routeDaemonPlistURL: URL {
        URL(fileURLWithPath: "/Library/LaunchDaemons/\(FirnRouteDaemon.label).plist")
    }
}

public enum FirnRouteDaemon {
    public static let label = "dev.firn.route"

    public static func plistContents(hostnetPath: String, utunSockURL: URL, stateDir: URL) -> String {
        let logPath = stateDir.appendingPathComponent("firn-route.log").path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(hostnetPath)</string>
                <string>utun</string>
                <string>--sock</string>
                <string>\(utunSockURL.path)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """
    }
}

public enum FirnLaunchAgent {
    public static let label = "dev.firn.firnd"

    public static func plistContents(firndPath: String, stateDir: URL) -> String {
        let logPath = stateDir.appendingPathComponent("firnd.log").path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(firndPath)</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>FIRN_HOME</key>
                <string>\(stateDir.path)</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """
    }
}

public func computeBalloonTargetBytes(
    usedGuestBytes: UInt64,
    minBalloonBytes: UInt64,
    maxMemoryBytes: UInt64,
    headroomBytes: UInt64 = 768 * 1024 * 1024
) -> UInt64 {
    let raw = min(maxMemoryBytes, max(minBalloonBytes, usedGuestBytes &+ headroomBytes))
    let mibAlignMask = ~UInt64((1 << 20) - 1)
    let aligned = raw & mibAlignMask
    return min(maxMemoryBytes, max(minBalloonBytes, aligned))
}
