import AppKit
import Combine
import Foundation
import FirnCore

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case stacks = "Stacks"
    case volumes = "Volumes"
    case cache = "Registry"
    case kubernetes = "Kubernetes"
    case machines = "Machines"
    case network = "Network & Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .stacks: return "shippingbox"
        case .volumes: return "externaldrive"
        case .cache: return "bolt.horizontal.circle"
        case .kubernetes: return "circle.hexagongrid"
        case .machines: return "desktopcomputer"
        case .network: return "slider.horizontal.3"
        }
    }
}

enum FirnVMState: String {
    case offline = "Offline"
    case hibernated = "Hibernated"
    case running = "Running"
}

struct FirnMetricSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let footprintMiB: Double
    let cpuPercent: Double
}

struct FirnMemoryPressureInfo {
    var enabled = true
    var level = "normal"
    var reclaimCount = 0
    var lastFrozenProjects: [String] = []
    var lastReclaimAt = ""
}

struct FirnCapabilitiesInfo {
    var firnfsActive = false
    var fastVirtioNet = false
    var nestedKvm = false
    var gpuDri = false
    var k3sRunning = false
    var utunConnected = false
    var metalDeviceName = ""
}

struct FirnDiskInfo {
    var hostAllocatedBytes: UInt64 = 0
    var hostLogicalBytes: UInt64 = 0
    var savedStateBytes: UInt64 = 0
    var guestTotalBytes: UInt64 = 0
    var guestUsedBytes: UInt64 = 0
    var guestAvailableBytes: UInt64 = 0
    var swapFileBytes: UInt64 = 0
    var zramDiskBytes: UInt64 = 0
    var zramUsedBytes: UInt64 = 0
    var dockerImagesBytes: UInt64 = 0
    var dockerContainersBytes: UInt64 = 0
    var dockerVolumesBytes: UInt64 = 0
    var dockerBuildCacheBytes: UInt64 = 0
    var dockerReclaimableBytes: UInt64 = 0
    var registryCacheBytes: UInt64 = 0
    var snapshotsBytes: UInt64 = 0
    var dockerDfPending = false
}

struct FirnNetworkInfo {
    var domain = "firn.local"
    var dnsPort = 53535
    var httpProxyPort = 8088
    var httpsProxyPort = 8443
    var recordCount = 0
    var portCount = 0
    var caTrusted = false
    var pfRedirectActive = false
    var directRouteDNS = false
    var hasResolver = false
    var routeDaemonInstalled = false
    var vpnActive = false
    var httpProxy = ""
    var sshAgentActive = false
    var currentDockerContext = ""
    var autostartInstalled = false
}

struct FirnContainerInfo: Identifiable {
    let id: String
    let name: String
    let service: String
    let state: String
    let paused: Bool
    let memoryBytes: UInt64
    let swapBytes: UInt64
    let established: Int
    let ip: String
}

struct FirnEndpointLink: Identifiable {
    let id = UUID()
    let label: String
    let httpsURL: URL?
    let httpURL: URL?
}

struct FirnStackInfo: Identifiable {
    var id: String { project }
    let project: String
    let workingDir: String
    let hasComposeProject: Bool
    let orphaned: Bool
    let exempt: Bool
    let idleForSeconds: Double
    let idleLimitSeconds: Int
    let runningCount: Int
    let pausedCount: Int
    let memoryBytes: UInt64
    let swapBytes: UInt64
    let established: Int
    let containers: [FirnContainerInfo]
    let endpoints: [FirnEndpointLink]
}

struct FirnVolumeSnapshotInfo: Identifiable {
    var id: String { name }
    let name: String
    let volume: String
    let files: UInt64
    let bytes: UInt64
    let cloneMode: String
    let createdAt: String
}

struct FirnDockerVolumeInfo: Identifiable {
    var id: String { name }
    let name: String
    let driver: String
    let mountpoint: String
}

struct FirnDockerImageInfo: Identifiable {
    let id: String
    let repository: String
    let tag: String
    let size: String
    let created: String

    var displayRef: String {
        tag.isEmpty || tag == "<none>" ? repository : "\(repository):\(tag)"
    }
}

struct FirnRegistryCacheInfo {
    var enabled = true
    var listening = false
    var mirrorURL = "http://127.0.0.1:5000"
    var upstream = "https://registry-1.docker.io"
    var usedBytes: UInt64 = 0
    var maxBytes: UInt64 = 10 * 1024 * 1024 * 1024
    var blobCount: UInt64 = 0
    var manifestCount: UInt64 = 0
    var hits: UInt64 = 0
    var misses: UInt64 = 0
    var savedBytes: UInt64 = 0
}

struct FirnK8sInfo {
    var enabled = false
    var running = false
    var ready = false
    var frozen = false
    var version = "k3s"
    var memoryBytes: UInt64 = 0
    var nodeName = ""
}

struct FirnK8sServiceInfo: Identifiable {
    var id: String { "\(namespace)/\(name)" }
    let namespace: String
    let name: String
    let clusterIP: String
    let ports: String
    let dnsNames: [String]
}

struct FirnMachineInfo: Identifiable {
    var id: String { name }
    let name: String
    let distro: String
    let state: String
    let memoryBytes: UInt64
    let container: String
    let dnsName: String
    let ip: String
}

struct FirnToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}

@MainActor
final class FirnLogSession: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    @Published var lines: [String] = []
    @Published var isStreaming = false
    @Published var isPaused = false
    @Published var searchText = ""

    private var proc: Process?
    private var outPipe: Pipe?
    private var bufferLine = ""

    init(title: String, subtitle: String = "") {
        self.title = title
        self.subtitle = subtitle
    }

    var filteredText: String {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return lines.joined(separator: "\n") }
        return lines.filter { $0.localizedCaseInsensitiveContains(q) }.joined(separator: "\n")
    }

    func startDockerLogs(executable: String, args: [String]) {
        stop()
        lines = []
        isStreaming = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        proc = p
        outPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty {
                DispatchQueue.main.async {
                    self?.isStreaming = false
                }
                return
            }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.appendChunk(chunk)
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isStreaming = false
            }
        }
        do {
            try p.run()
        } catch {
            lines = ["Failed to stream logs: \(error.localizedDescription)"]
            isStreaming = false
        }
    }

    private func appendChunk(_ chunk: String) {
        bufferLine += chunk
        let parts = bufferLine.components(separatedBy: "\n")
        guard parts.count > 1 else { return }
        bufferLine = parts.last ?? ""
        if !isPaused {
            lines.append(contentsOf: parts.dropLast())
            if lines.count > 2500 {
                lines.removeFirst(lines.count - 2500)
            }
        }
    }

    func clear() {
        lines.removeAll()
        bufferLine = ""
    }

    func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(filteredText, forType: .string)
    }

    func stop() {
        outPipe?.fileHandleForReading.readabilityHandler = nil
        if let p = proc, p.isRunning {
            p.terminate()
        }
        proc = nil
        outPipe = nil
        isStreaming = false
    }
}

@MainActor
final class FirnStore: ObservableObject {
    @Published var selectedSection: DashboardSection = .overview
    @Published var vmState: FirnVMState = .offline
    @Published var backend = "vz"
    @Published var hibernateMode = "snapshot"
    @Published var cliVersion = FirnVersion.current
    @Published var availableUpdateTag: String?

    @Published var hostFootprintBytes: UInt64 = 0
    @Published var hostRSSBytes: UInt64 = 0
    @Published var daemonFootprintBytes: UInt64 = 0
    @Published var vmFootprintBytes: UInt64 = 0
    @Published var cpuPercent: Double = 0

    @Published var vmMemTotal: UInt64 = 0
    @Published var vmMemAvail: UInt64 = 0
    @Published var vmMemUsed: UInt64 = 0
    @Published var swapUsed: UInt64 = 0
    @Published var swapTotal: UInt64 = 0
    @Published var balloonTarget: UInt64 = 0
    @Published var balloonMax: UInt64 = 0

    @Published var pressure = FirnMemoryPressureInfo()
    @Published var capabilities = FirnCapabilitiesInfo()
    @Published var disk = FirnDiskInfo()
    @Published var network = FirnNetworkInfo()

    @Published var stacks: [FirnStackInfo] = []
    @Published var snapshots: [FirnVolumeSnapshotInfo] = []
    @Published var dockerVolumes: [FirnDockerVolumeInfo] = []
    @Published var dockerImages: [FirnDockerImageInfo] = []
    @Published var cache = FirnRegistryCacheInfo()
    @Published var k8s = FirnK8sInfo()
    @Published var k8sServices: [FirnK8sServiceInfo] = []
    @Published var machines: [FirnMachineInfo] = []

    @Published var samples: [FirnMetricSample] = []
    @Published var config = FirnConfig.load()
    @Published var busyAction: String?
    @Published var toast: FirnToast?
    @Published var lastUpdated: Date?
    @Published var activeLogSession: FirnLogSession?

    var onRequestRefresh: (() -> Void)?
    private var toastDismissTask: Task<Void, Never>?

    static func findDockerExecutable() -> String {
        for path in ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "/usr/bin/env"
    }

    static func siblingCLIExecutable() -> String {
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        let candidates = [
            bundleParent.appendingPathComponent("firn").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/firn").path,
            "/opt/homebrew/bin/firn",
            "/usr/local/bin/firn",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "firn"
    }

    var orphanedCount: Int {
        stacks.filter(\.orphaned).count
    }

    var runningContainersTotal: Int {
        stacks.reduce(0) { $0 + $1.runningCount }
    }

    var pausedContainersTotal: Int {
        stacks.reduce(0) { $0 + $1.pausedCount }
    }

    func applyPayloads(
        statusPayload: [String: Any]?,
        dnsPayload: [String: Any]?,
        k8sPayload: [String: Any]?,
        machinesPayload: [String: Any]?,
        diskPayload: [String: Any]?,
        k8sServicesPayload: [String: Any]?,
        volumesPayload: [String: Any]?,
        cachePayload: [String: Any]?,
        currentDockerContext: String?,
        availableUpdateTag: String?
    ) {
        self.availableUpdateTag = availableUpdateTag
        self.config = FirnConfig.load()
        self.lastUpdated = Date()

        guard let status = statusPayload else {
            vmState = .offline
            stacks = []
            var net = FirnNetworkInfo()
            net.domain = config.domain
            net.dnsPort = Int(config.dnsPort)
            net.httpProxyPort = Int(config.httpProxyPort)
            net.httpsProxyPort = Int(config.httpsProxyPort)
            net.currentDockerContext = currentDockerContext ?? ""
            net.autostartInstalled = FileManager.default.fileExists(atPath: FirnPaths.launchAgentURL.path)
            net.hasResolver = FileManager.default.fileExists(atPath: "/etc/resolver/\(config.domain)")
            net.routeDaemonInstalled = FileManager.default.fileExists(atPath: FirnPaths.routeDaemonPlistURL.path)
            network = net
            return
        }

        let hib = (status["hibernated"] as? Bool) ?? false
        vmState = hib ? .hibernated : .running
        backend = (status["backend"] as? String) ?? "vz"
        hibernateMode = (status["hibernateMode"] as? String) ?? "snapshot"

        let hostMem = (status["hostMemory"] as? [String: Any]) ?? [:]
        hostFootprintBytes = u64(hostMem, "footprintBytes")
        hostRSSBytes = u64(hostMem, "rssBytes")
        daemonFootprintBytes = u64(hostMem, "daemonFootprintBytes")
        vmFootprintBytes = u64(hostMem, "vmFootprintBytes")
        cpuPercent = (hostMem["cpuPercent"] as? NSNumber)?.doubleValue ?? 0

        if let last = samples.last, Date().timeIntervalSince(last.timestamp) < 1.2 {
            // Avoid tight bursts from double triggers
        } else {
            samples.append(FirnMetricSample(
                timestamp: Date(),
                footprintMiB: Double(hostFootprintBytes) / (1024.0 * 1024.0),
                cpuPercent: cpuPercent
            ))
            if samples.count > 60 {
                samples.removeFirst(samples.count - 60)
            }
        }

        let vmMem = (status["vmMemory"] as? [String: Any]) ?? [:]
        vmMemTotal = u64(vmMem, "totalBytes")
        vmMemAvail = u64(vmMem, "availableBytes")
        vmMemUsed = vmMemTotal > vmMemAvail ? vmMemTotal - vmMemAvail : 0
        swapUsed = u64(vmMem, "swapUsedBytes")
        swapTotal = u64(vmMem, "swapTotalBytes")

        let bal = (status["balloon"] as? [String: Any]) ?? [:]
        balloonTarget = u64(bal, "targetBytes")
        balloonMax = u64(bal, "maxBytes")

        let mp = (status["memoryPressure"] as? [String: Any]) ?? [:]
        pressure = FirnMemoryPressureInfo(
            enabled: (mp["enabled"] as? Bool) ?? config.memoryPressureReclaim,
            level: (mp["level"] as? String) ?? "normal",
            reclaimCount: Int(u64(mp, "reclaimCount")),
            lastFrozenProjects: (mp["lastFrozenProjects"] as? [String]) ?? [],
            lastReclaimAt: (mp["lastReclaimAt"] as? String) ?? ""
        )

        let caps = (status["capabilities"] as? [String: Any]) ?? [:]
        let routeObj = (status["route"] as? [String: Any]) ?? [:]
        capabilities = FirnCapabilitiesInfo(
            firnfsActive: (caps["firnfsActive"] as? Bool) ?? false,
            fastVirtioNet: (caps["fastVirtioNet"] as? Bool) ?? false,
            nestedKvm: (caps["nestedKvm"] as? Bool) ?? false,
            gpuDri: (caps["gpuDri"] as? Bool) ?? false,
            k3sRunning: (caps["k3sRunning"] as? Bool) ?? false,
            utunConnected: (routeObj["utunConnected"] as? Bool) ?? false,
            metalDeviceName: (caps["metalDeviceName"] as? String) ?? ""
        )

        let diskStatus = (status["disk"] as? [String: Any]) ?? [:]
        let guestDisk = (diskPayload?["guest"] as? [String: Any]) ?? [:]
        disk = FirnDiskInfo(
            hostAllocatedBytes: u64(diskStatus, "hostAllocatedBytes"),
            hostLogicalBytes: u64(diskStatus, "hostLogicalBytes"),
            savedStateBytes: u64(diskStatus, "savedStateBytes"),
            guestTotalBytes: u64(guestDisk, "totalBytes"),
            guestUsedBytes: u64(guestDisk, "usedBytes"),
            guestAvailableBytes: u64(guestDisk, "availableBytes"),
            swapFileBytes: u64(guestDisk, "swapFileBytes"),
            zramDiskBytes: u64(guestDisk, "zramDiskBytes"),
            zramUsedBytes: u64(guestDisk, "zramUsedBytes"),
            dockerImagesBytes: u64(guestDisk, "dockerImagesBytes"),
            dockerContainersBytes: u64(guestDisk, "dockerContainersBytes"),
            dockerVolumesBytes: u64(guestDisk, "dockerVolumesBytes"),
            dockerBuildCacheBytes: u64(guestDisk, "dockerBuildCacheBytes"),
            dockerReclaimableBytes: u64(guestDisk, "dockerReclaimableBytes"),
            registryCacheBytes: u64(guestDisk, "registryCacheBytes"),
            snapshotsBytes: u64(guestDisk, "snapshotsBytes"),
            dockerDfPending: (guestDisk["dockerDfPending"] as? Bool) ?? false
        )

        let dnsObj = (status["dns"] as? [String: Any]) ?? [:]
        let proxyObj = (status["proxy"] as? [String: Any]) ?? [:]
        let domain = (dnsObj["domain"] as? String) ?? config.domain
        let httpP = Int(u64(dnsObj, "httpProxyPort") > 0 ? u64(dnsObj, "httpProxyPort") : UInt64(config.httpProxyPort))
        let httpsP = Int(u64(dnsObj, "httpsProxyPort") > 0 ? u64(dnsObj, "httpsProxyPort") : UInt64(config.httpsProxyPort))
        network = FirnNetworkInfo(
            domain: domain,
            dnsPort: Int(u64(dnsObj, "dnsPort") > 0 ? u64(dnsObj, "dnsPort") : UInt64(config.dnsPort)),
            httpProxyPort: httpP,
            httpsProxyPort: httpsP,
            recordCount: Int(u64(dnsObj, "recordCount")),
            portCount: Int(u64(status, "ports")),
            caTrusted: (dnsObj["caTrusted"] as? Bool) ?? false,
            pfRedirectActive: (dnsObj["pfRedirectActive"] as? Bool) ?? false,
            directRouteDNS: (dnsObj["directRouteDNS"] as? Bool) ?? config.directRouteDNS,
            hasResolver: FileManager.default.fileExists(atPath: "/etc/resolver/\(domain)"),
            routeDaemonInstalled: (routeObj["routeDaemonInstalled"] as? Bool) ?? false,
            vpnActive: (proxyObj["vpnActive"] as? Bool) ?? false,
            httpProxy: (proxyObj["httpProxy"] as? String) ?? "",
            sshAgentActive: (proxyObj["sshAgentActive"] as? Bool) ?? false,
            currentDockerContext: currentDockerContext ?? "",
            autostartInstalled: FileManager.default.fileExists(atPath: FirnPaths.launchAgentURL.path)
        )

        let records = (dnsPayload?["records"] as? [[String: Any]]) ?? []
        let rawProjects = (status["projects"] as? [[String: Any]]) ?? []
        stacks = rawProjects.map { p in
            let pName = (p["project"] as? String) ?? "unknown"
            let rawContainers = (p["containers"] as? [[String: Any]]) ?? []
            let containers = rawContainers.map { c in
                FirnContainerInfo(
                    id: (c["id"] as? String) ?? UUID().uuidString,
                    name: (c["name"] as? String) ?? "",
                    service: (c["service"] as? String) ?? "",
                    state: (c["state"] as? String) ?? "",
                    paused: (c["paused"] as? Bool) ?? false,
                    memoryBytes: u64(c, "memoryBytes"),
                    swapBytes: u64(c, "swapBytes"),
                    established: Int(u64(c, "established")),
                    ip: (c["ip"] as? String) ?? ""
                )
            }
            let links: [FirnEndpointLink] = records.compactMap { rec in
                guard (rec["project"] as? String) == pName,
                      Int(u64(rec, "httpPort")) > 0 else { return nil }
                let names = (rec["names"] as? [String]) ?? []
                guard let fqdn = names.first(where: { $0.contains(".\(pName).") }) ?? names.first else {
                    return nil
                }
                return FirnEndpointLink(
                    label: (rec["service"] as? String) ?? fqdn,
                    httpsURL: URL(string: "https://\(fqdn):\(httpsP)/"),
                    httpURL: URL(string: "http://\(fqdn):\(httpP)/")
                )
            }
            return FirnStackInfo(
                project: pName,
                workingDir: (p["workingDir"] as? String) ?? "",
                hasComposeProject: (p["hasComposeProject"] as? Bool) ?? false,
                orphaned: (p["orphaned"] as? Bool) ?? false,
                exempt: (p["exempt"] as? Bool) ?? false,
                idleForSeconds: (p["idleForSeconds"] as? NSNumber)?.doubleValue ?? 0,
                idleLimitSeconds: Int(u64(p, "idleLimitSeconds")),
                runningCount: Int(u64(p, "runningCount")),
                pausedCount: Int(u64(p, "pausedCount")),
                memoryBytes: u64(p, "memoryBytes"),
                swapBytes: u64(p, "swapBytes"),
                established: Int(u64(p, "established")),
                containers: containers,
                endpoints: links
            )
        }

        let rawSnaps = (volumesPayload?["snapshots"] as? [[String: Any]]) ?? []
        snapshots = rawSnaps.map { s in
            FirnVolumeSnapshotInfo(
                name: (s["name"] as? String) ?? "",
                volume: (s["volume"] as? String) ?? "",
                files: u64(s, "files"),
                bytes: u64(s, "bytes"),
                cloneMode: (s["cloneMode"] as? String) ?? "copy",
                createdAt: (s["createdAt"] as? String) ?? ""
            )
        }

        cache = FirnRegistryCacheInfo(
            enabled: (cachePayload?["enabled"] as? Bool) ?? true,
            listening: (cachePayload?["listening"] as? Bool) ?? false,
            mirrorURL: (cachePayload?["mirrorUrl"] as? String) ?? "http://127.0.0.1:5000",
            upstream: (cachePayload?["upstream"] as? String) ?? "https://registry-1.docker.io",
            usedBytes: u64(cachePayload ?? [:], "usedBytes"),
            maxBytes: max(1, u64(cachePayload ?? [:], "maxBytes")),
            blobCount: u64(cachePayload ?? [:], "blobCount"),
            manifestCount: u64(cachePayload ?? [:], "manifestCount"),
            hits: u64(cachePayload ?? [:], "hits"),
            misses: u64(cachePayload ?? [:], "misses"),
            savedBytes: u64(cachePayload ?? [:], "savedBytes")
        )

        k8s = FirnK8sInfo(
            enabled: (k8sPayload?["enabled"] as? Bool) ?? false,
            running: (k8sPayload?["running"] as? Bool) ?? capabilities.k3sRunning,
            ready: (k8sPayload?["ready"] as? Bool) ?? false,
            frozen: (k8sPayload?["frozen"] as? Bool) ?? false,
            version: (k8sPayload?["version"] as? String) ?? "k3s",
            memoryBytes: u64(k8sPayload ?? [:], "memoryBytes"),
            nodeName: (k8sPayload?["nodeName"] as? String) ?? ""
        )

        let rawSvcs = (k8sServicesPayload?["services"] as? [[String: Any]]) ?? []
        k8sServices = rawSvcs.map { svc in
            FirnK8sServiceInfo(
                namespace: (svc["namespace"] as? String) ?? "default",
                name: (svc["name"] as? String) ?? "",
                clusterIP: (svc["clusterIP"] as? String) ?? "",
                ports: (svc["portsSummary"] as? String) ?? "",
                dnsNames: (svc["dnsNames"] as? [String]) ?? []
            )
        }

        let rawMachines = (machinesPayload?["machines"] as? [[String: Any]]) ?? []
        machines = rawMachines.map { m in
            let name = (m["name"] as? String) ?? "unknown"
            return FirnMachineInfo(
                name: name,
                distro: (m["distro"] as? String) ?? "",
                state: (m["state"] as? String) ?? "",
                memoryBytes: u64(m, "memoryBytes"),
                container: (m["container"] as? String) ?? "firn-machine-\(name)",
                dnsName: (m["dnsName"] as? String) ?? "\(name).\(domain)",
                ip: (m["ip"] as? String) ?? ""
            )
        }
    }

    func showToast(_ message: String, isError: Bool = false) {
        toastDismissTask?.cancel()
        toast = FirnToast(message: message, isError: isError)
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled {
                toast = nil
            }
        }
    }

    func refreshDockerInventory() {
        guard vmState == .running else { return }
        let exe = Self.findDockerExecutable()
        let prefix = exe == "/usr/bin/env" ? ["docker"] : []
        DispatchQueue.global(qos: .utility).async {
            let vols = Self.runDockerLines(exe: exe, args: prefix + ["--context", FirnConfig.defaultDockerContext, "volume", "ls", "--format", "{{.Name}}\t{{.Driver}}\t{{.Mountpoint}}"])
            let imgs = Self.runDockerLines(exe: exe, args: prefix + ["--context", FirnConfig.defaultDockerContext, "images", "--format", "{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}"])

            let parsedVols: [FirnDockerVolumeInfo] = vols.compactMap { line in
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard !cols.isEmpty, !cols[0].isEmpty else { return nil }
                return FirnDockerVolumeInfo(
                    name: cols[0],
                    driver: cols.count > 1 ? cols[1] : "local",
                    mountpoint: cols.count > 2 ? cols[2] : ""
                )
            }
            let parsedImgs: [FirnDockerImageInfo] = imgs.compactMap { line in
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard cols.count >= 4, !cols[0].isEmpty else { return nil }
                return FirnDockerImageInfo(
                    id: cols[0],
                    repository: cols[1],
                    tag: cols[2],
                    size: cols[3],
                    created: cols.count > 4 ? cols[4] : ""
                )
            }
            DispatchQueue.main.async {
                self.dockerVolumes = parsedVols
                self.dockerImages = parsedImgs
            }
        }
    }

    func triggerFullDiskRefresh() {
        performDaemonPost(label: "Calculating Docker disk breakdown…", path: "/disk/usage?refresh=1", method: "GET", timeoutSeconds: 60) { _ in
            "Disk usage refreshed"
        }
    }

    func performDaemonPost(
        label: String,
        path: String,
        method: String = "POST",
        body: [String: Any]? = nil,
        timeoutSeconds: Int = 60,
        successMessage: ((_ response: [String: Any]) -> String)? = nil
    ) {
        busyAction = label
        let payloadData: Data? = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let res = try FirnHostClient.requestJSON(method: method, path: path, body: payloadData, timeoutSeconds: timeoutSeconds)
                let msg = successMessage?(res) ?? "Done"
                DispatchQueue.main.async {
                    self.busyAction = nil
                    self.showToast(msg)
                    self.onRequestRefresh?()
                    self.refreshDockerInventory()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busyAction = nil
                    self.showToast(error.localizedDescription, isError: true)
                }
            }
        }
    }

    func performCLI(label: String, args: [String], successMessage: String) {
        busyAction = label
        let cli = Self.siblingCLIExecutable()
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            if cli == "firn" {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = ["firn"] + args
            } else {
                p.executableURL = URL(fileURLWithPath: cli)
                p.arguments = args
            }
            let errPipe = Pipe()
            p.standardError = errPipe
            do {
                try p.run()
                p.waitUntilExit()
                let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async {
                    self.busyAction = nil
                    if p.terminationStatus == 0 {
                        self.showToast(successMessage)
                    } else {
                        self.showToast(errText.isEmpty ? "Command failed (\(p.terminationStatus))" : errText, isError: true)
                    }
                    self.onRequestRefresh?()
                    self.refreshDockerInventory()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busyAction = nil
                    self.showToast(error.localizedDescription, isError: true)
                }
            }
        }
    }

    func performDocker(label: String, args: [String], successMessage: String) {
        busyAction = label
        let exe = Self.findDockerExecutable()
        let prefix = exe == "/usr/bin/env" ? ["docker"] : []
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = prefix + ["--context", FirnConfig.defaultDockerContext] + args
            let errPipe = Pipe()
            p.standardError = errPipe
            do {
                try p.run()
                p.waitUntilExit()
                let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async {
                    self.busyAction = nil
                    if p.terminationStatus == 0 {
                        self.showToast(successMessage)
                    } else {
                        self.showToast(errText.isEmpty ? "Docker failed (\(p.terminationStatus))" : errText, isError: true)
                    }
                    self.onRequestRefresh?()
                    self.refreshDockerInventory()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busyAction = nil
                    self.showToast(error.localizedDescription, isError: true)
                }
            }
        }
    }

    func openLogsSheet(title: String, subtitle: String, dockerArgs: [String]) {
        let exe = Self.findDockerExecutable()
        let prefix = exe == "/usr/bin/env" ? ["docker"] : []
        activeLogSession?.stop()
        let session = FirnLogSession(title: title, subtitle: subtitle)
        session.startDockerLogs(executable: exe, args: prefix + ["--context", FirnConfig.defaultDockerContext] + dockerArgs)
        activeLogSession = session
    }

    func closeLogsSheet() {
        activeLogSession?.stop()
        activeLogSession = nil
    }

    func openTerminalShell(cliArgs: [String]) {
        openTerminalCommand(executable: Self.siblingCLIExecutable(), args: cliArgs)
    }

    func openDockerExecInTerminal(containerName: String) {
        let exe = Self.findDockerExecutable()
        let prefix = exe == "/usr/bin/env" ? ["docker"] : []
        let cli = Self.siblingCLIExecutable()
        showToast("Inspecting '\(containerName)'…")

        DispatchQueue.global(qos: .userInitiated).async {
            let inspectArgs = prefix + [
                "--context", FirnConfig.defaultDockerContext,
                "inspect", "--format",
                "{{.State.Running}}\t{{.State.Paused}}\t{{.State.Pid}}\t{{.Config.Image}}",
                containerName,
            ]
            let inspect = Self.runProcessOutput(executable: exe, args: inspectArgs)
            guard inspect.status == 0 else {
                Task { @MainActor in
                    self.showToast("Failed to inspect container '\(containerName)'", isError: true)
                }
                return
            }

            let fields = inspect.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\t")
            let isRunning = fields.count > 0 && fields[0] == "true"
            let isPaused = fields.count > 1 && fields[1] == "true"
            let pid = fields.count > 2 ? (Int(fields[2]) ?? 0) : 0
            let image = fields.count > 3 ? fields[3] : containerName

            if isPaused {
                Task { @MainActor in
                    self.showToast("Container '\(containerName)' is frozen — thaw the stack first", isError: true)
                }
                return
            }
            guard isRunning, pid > 0 else {
                Task { @MainActor in
                    self.showToast("Container '\(containerName)' is not running", isError: true)
                }
                return
            }

            let candidates = ["/bin/bash", "/bin/sh", "/bin/ash", "/busybox/sh"]
            var detectedShell: String?
            for shell in candidates {
                let probeArgs = prefix + [
                    "--context", FirnConfig.defaultDockerContext,
                    "exec", containerName, shell, "-c", "true",
                ]
                if Self.runProcessOutput(executable: exe, args: probeArgs).status == 0 {
                    detectedShell = shell
                    break
                }
            }

            if let shell = detectedShell {
                Task { @MainActor in
                    self.openTerminalCommand(
                        executable: exe,
                        args: prefix + ["--context", FirnConfig.defaultDockerContext, "exec", "-it", containerName, shell]
                    )
                }
                return
            }

            let debugScript = #"printf '[firn] Container %s (%s) has no /bin/sh (distroless/scratch image).\n[firn] Attached Firn debug shell in container net/ipc/uts namespaces (PID %s).\n[firn] Container rootfs: /proc/%s/root  |  Tools: bash, curl, ip, ss, ps\n\n' "$1" "$2" "$3" "$3"; export FIRN_CONTAINER_ROOT="/proc/$3/root"; export PS1="[firn-debug:$1] # "; exec /bin/bash --norc"#
            let debugArgs = [
                "shell", "-t", "--",
                "nsenter", "-t", "\(pid)", "-n", "-i", "-u", "--",
                "/bin/sh", "-c", debugScript, "_", containerName, image, "\(pid)",
            ]
            Task { @MainActor in
                self.openTerminalCommand(executable: cli, args: debugArgs, customToast: "Opened Firn debug shell for distroless '\(containerName)'")
            }
        }
    }

    func openTerminalCommand(executable: String, args: [String], customToast: String = "Opened in Terminal") {
        let quoted = ([executable] + args).map { arg in
            "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
        let appleEscaped = quoted
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(appleEscaped)"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
        showToast(customToast)
    }

    nonisolated private static func runProcessOutput(executable: String, args: [String]) -> (status: Int32, stdout: String) {
        let p = Process()
        if executable == "/usr/bin/env" {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = args
        } else {
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "")
        }
    }

    func saveRuntimeConfig(_ next: FirnConfig) {
        let payload: [String: Any] = [
            "cpus": next.cpus,
            "memoryGiB": next.memoryGiB,
            "minBalloonMiB": next.minBalloonMiB,
            "idleSeconds": next.idleSeconds,
            "hibernateSeconds": next.hibernateSeconds,
            "domain": next.domain,
            "exemptProjects": next.exemptProjects,
            "diskSyncMode": next.diskSyncMode,
            "fsMode": next.fsMode,
            "nestedVirtualization": next.nestedVirtualization,
            "directRouteDNS": next.directRouteDNS,
            "autoTrimMinutes": next.autoTrimMinutes,
            "memoryPressureReclaim": next.memoryPressureReclaim,
        ]
        if FirnHostClient.isDaemonAlive() {
            performDaemonPost(label: "Saving runtime configuration…", path: "/config", body: payload, timeoutSeconds: 10) { resp in
                let restart = (resp["restartRequired"] as? Bool) ?? false
                return restart ? "Saved (restart Firn VM for VM-hardware changes)" : "Configuration saved & applied live"
            }
        } else {
            do {
                try next.save()
                config = next
                showToast("Saved to ~/.firn/config.json")
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    nonisolated private static func runDockerLines(exe: String, args: [String]) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, let str = String(data: data, encoding: .utf8) else { return [] }
            return str.split(separator: "\n").map(String.init)
        } catch {
            return []
        }
    }

    private func u64(_ dict: [String: Any], _ key: String) -> UInt64 {
        (dict[key] as? NSNumber)?.uint64Value ?? 0
    }
}
