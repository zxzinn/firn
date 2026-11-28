import Foundation
import FirnCore
import Security

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

private func expect(_ condition: Bool, _ message: String) {
    if !condition { fail(message) }
}

private func buildSampleQuery(name: String, qtype: UInt16 = 1) -> Data {
    var data = Data([0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    for part in name.split(separator: ".") {
        let bytes = Array(part.utf8)
        data.append(UInt8(bytes.count))
        data.append(contentsOf: bytes)
    }
    data.append(0)
    data.append(UInt8(qtype >> 8))
    data.append(UInt8(qtype & 0xFF))
    data.append(contentsOf: [0x00, 0x01])
    return data
}

let queryA = buildSampleQuery(name: "mailpit.proj.firn.local", qtype: 1)
guard let respA = WireDNS.buildLocalResponse(for: queryA, domain: "firn.local", knownNames: []) else {
    fail("Expected A response for firn.local")
}
expect(Array(respA.suffix(4)) == [127, 0, 0, 1], "Expected 127.0.0.1 in DNS A answer")

let queryAAAA = buildSampleQuery(name: "mailpit.proj.firn.local", qtype: 28)
guard let respAAAA = WireDNS.buildLocalResponse(for: queryAAAA, domain: "firn.local", knownNames: []) else {
    fail("Expected AAAA response for firn.local")
}
expect(respAAAA.last == 1, "Expected ::1 in DNS AAAA answer")

guard let respDirect = WireDNS.buildLocalResponse(for: queryA, domain: "firn.local", knownNames: [], directIPv4: "10.88.0.12") else {
    fail("Expected direct A response for firn.local")
}
expect(Array(respDirect.suffix(4)) == [10, 88, 0, 12], "Expected direct container IP 10.88.0.12 in DNS A answer")

let externalQuery = buildSampleQuery(name: "example.com", qtype: 1)
expect(WireDNS.buildLocalResponse(for: externalQuery, domain: "firn.local", knownNames: []) == nil, "External query should not be answered locally")

let defaultCfg = FirnConfig()
expect(defaultCfg.exemptProjects.isEmpty, "Open-source default exemptProjects must be empty")
expect(defaultCfg.httpsProxyPort == 8443, "Default httpsProxyPort must be 8443")
expect(defaultCfg.fsMode == "firnfs" && defaultCfg.diskSyncMode == "none" && !defaultCfg.nestedVirtualization, "Expected v0.5.0 default config flags")

expect(FirnVersion.compare("0.4.0", "0.5.0") == .orderedAscending, "0.4.0 < 0.5.0 failed")
expect(FirnVersion.compare("0.9.0", "0.10.0") == .orderedAscending, "0.9.0 < 0.10.0 failed")
expect(FirnVersion.compare("v0.5.0-rc.1", "0.5.0") == .orderedAscending, "prerelease ordering failed")
expect(FirnVersion.compare("v0.5.0", "0.5.0") == .orderedSame, "v0.5.0 == 0.5.0 failed")
expect(FirnVersion.normalizedTag("0.5.0") == "v0.5.0", "normalizedTag failed")

expect(FirnInstallOrigin.detect(executablePath: "/opt/homebrew/Cellar/firn/0.5.0/bin/firn") == .homebrew(cellarPath: "/opt/homebrew/Cellar/firn/0.5.0"), "Homebrew origin detect failed")
expect(FirnInstallOrigin.detect(executablePath: "/opt/firn/bin/firn") == .standalone(binDir: URL(fileURLWithPath: "/opt/firn/bin")), "Standalone origin detect failed")
let absExe = FirnInstallOrigin.currentExecutablePath()
expect(absExe.hasPrefix("/"), "currentExecutablePath must return an absolute path, got \(absExe)")
if let pathEnv = ProcessInfo.processInfo.environment["PATH"], let firstDir = pathEnv.split(separator: ":").first.map(String.init) {
    let fakeBinDir = FileManager.default.temporaryDirectory.appendingPathComponent("firn-path-check-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: fakeBinDir, withIntermediateDirectories: true)
    let fakeExe = fakeBinDir.appendingPathComponent("firn-check-dummy")
    FileManager.default.createFile(atPath: fakeExe.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    setenv("PATH", "\(fakeBinDir.path):\(pathEnv)", 1)
    let detectedBare = FirnInstallOrigin.detect(executablePath: "firn-check-dummy")
    expect(detectedBare == .standalone(binDir: fakeBinDir.resolvingSymlinksInPath()), "Bare PATH origin detect failed: got \(detectedBare) vs \(fakeBinDir.path)")
    setenv("PATH", pathEnv, 1)
    try? FileManager.default.removeItem(at: fakeBinDir)
    _ = firstDir
}

let sampleSums = """
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  firn-darwin-arm64.tar.gz
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb *./firn-linux-arm64-images.tar.gz
"""
let parsedSums = FirnDistribution.parseSHA256Sums(sampleSums)
expect(parsedSums["firn-darwin-arm64.tar.gz"] == String(repeating: "a", count: 64), "parseSHA256Sums darwin mismatch")
expect(parsedSums["firn-linux-arm64-images.tar.gz"] == String(repeating: "b", count: 64), "parseSHA256Sums images mismatch")

let tmpStateDir = FileManager.default.temporaryDirectory.appendingPathComponent("firn-check-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: tmpStateDir) }
var customCfg = FirnConfig(cpus: 6, memoryGiB: 6, idleSeconds: 420, exemptProjects: ["db"])
customCfg.httpsProxyPort = 9443
customCfg.hibernateSeconds = 1800
customCfg.fsMode = "virtiofs"
customCfg.diskSyncMode = "fsync"
try customCfg.save(to: tmpStateDir)
let reloadedCfg = FirnConfig.load(from: tmpStateDir)
expect(reloadedCfg == customCfg, "FirnConfig save/load roundtrip mismatch")

let minB: UInt64 = 768 * 1024 * 1024
let maxB: UInt64 = 8 * 1024 * 1024 * 1024
let headroom: UInt64 = 768 * 1024 * 1024
let unalignedTarget = computeBalloonTargetBytes(
    usedGuestBytes: 100 * 1024 * 1024 + 512 * 1024,
    minBalloonBytes: minB,
    maxMemoryBytes: maxB,
    headroomBytes: headroom
)
expect(unalignedTarget == 100 * 1024 * 1024 + headroom, "Balloon headroom / 1 MiB alignment mismatch: \(unalignedTarget)")
expect(computeBalloonTargetBytes(usedGuestBytes: maxB, minBalloonBytes: minB, maxMemoryBytes: maxB) == maxB, "Balloon max clamp mismatch")
expect(computeBalloonTargetBytes(usedGuestBytes: 10 * 1024 * 1024, minBalloonBytes: minB, maxMemoryBytes: maxB, headroomBytes: 128 * 1024 * 1024) == minB, "Balloon min clamp mismatch")

let resolver = LocalDNSServer.macOSResolverFileContents(domain: "firn.local", port: 53535)
expect(resolver.contains("# Generated by Firn") && resolver.contains("nameserver 127.0.0.1") && resolver.contains("port 53535"), "Resolver file format mismatch")

let pfAnchor = CertAuthority.pfAnchorContents(httpPort: 8088, httpsPort: 8443)
expect(pfAnchor.contains("127.0.0.1 port 443 -> 127.0.0.1 port 8443") && pfAnchor.contains("::1 port 80 -> ::1 port 8088"), "pf anchor contents mismatch")

let tmpCertDir = tmpStateDir.appendingPathComponent("certs")
let identity = try CertAuthority.ensureServerIdentity(domain: "firn.local", projects: ["demo-app"], in: tmpCertDir)
var secCert: SecCertificate?
expect(SecIdentityCopyCertificate(identity, &secCert) == errSecSuccess && secCert != nil, "Expected valid SecIdentity certificate")
let caStatus = CertAuthority.caTrustStatus(in: tmpCertDir)
expect(caStatus.exists && caStatus.fingerprint.contains("SHA256") || caStatus.fingerprint.contains("Fingerprint"), "Expected CA cert + fingerprint, got \(caStatus)")

let plist = FirnLaunchAgent.plistContents(firndPath: "/usr/local/bin/firnd", stateDir: URL(fileURLWithPath: "/tmp/firn-home"))
expect(plist.contains("dev.firn.firnd") && plist.contains("/usr/local/bin/firnd") && plist.contains("/tmp/firn-home/firnd.log") && plist.contains("<key>ExitTimeOut</key>"), "LaunchAgent plist mismatch")
let routePlist = FirnRouteDaemon.plistContents(hostnetPath: "/usr/local/bin/firn-hostnet", utunSockURL: URL(fileURLWithPath: "/tmp/firn-home/run/utun.sock"), stateDir: URL(fileURLWithPath: "/tmp/firn-home"))
expect(routePlist.contains("dev.firn.route") && routePlist.contains("utun") && routePlist.contains("/tmp/firn-home/run/utun.sock"), "RouteDaemon plist mismatch")

let probeFile = tmpStateDir.appendingPathComponent("sparse-test.bin")
FileManager.default.createFile(atPath: probeFile.path, contents: Data(repeating: 0x41, count: 8192))
let diskStats = FirnHostClient.hostSparseFileStats(at: probeFile)
expect(diskStats.logicalBytes == 8192 && diskStats.allocatedBytes > 0, "Expected hostSparseFileStats logical=8192 allocated>0")
let digest = try FirnHostClient.sha256Hex(of: probeFile)
expect(digest.count == 64, "Expected 64-char sha256 digest")

let bigProbe = tmpStateDir.appendingPathComponent("multi-chunk.bin")
let chunkData = Data(repeating: 0x5A, count: 1_200_000)
try chunkData.write(to: bigProbe)
let bigDigest = try FirnHostClient.sha256Hex(of: bigProbe)
expect(bigDigest.count == 64, "Expected multi-chunk sha256 digest")

let sparseDataDisk = tmpStateDir.appendingPathComponent("data.ext4")
let createdSparse = try FirnDistribution.ensureSparseDataDisk(at: sparseDataDisk, sizeGiB: 120)
let createdAgain = try FirnDistribution.ensureSparseDataDisk(at: sparseDataDisk, sizeGiB: 120)
let sparseStats = FirnHostClient.hostSparseFileStats(at: sparseDataDisk)
expect(createdSparse && !createdAgain, "ensureSparseDataDisk creation/idempotency mismatch")
expect(sparseStats.logicalBytes == 120 * 1024 * 1024 * 1024 && sparseStats.allocatedBytes < 1024 * 1024, "Sparse disk allocation mismatch: \(sparseStats)")

let imgDir = tmpStateDir.appendingPathComponent("images")
expect(FirnDistribution.missingGuestImages(in: imgDir).count == 3, "Expected 3 missing images in empty dir")
try FirnDistribution.recordInstalledImageVersion("v0.5.0", in: imgDir)
expect(FirnDistribution.installedImageVersion(in: imgDir) == "v0.5.0", "installedImageVersion mismatch")

expect(FirnHostClient.formatBytes(512 * 1024) == "0.5 MiB", "formatBytes MiB mismatch")
expect(FirnHostClient.formatBytes(2 * 1024 * 1024 * 1024) == "2.00 GiB", "formatBytes GiB mismatch")

expect(HostProcessMetrics.samplePID(getpid())?.footprint ?? 0 > 0, "Expected non-zero proc_pid_rusage footprint for current process")
_ = FirnHostClient.metalGPUDeviceName()

// v0.6.x & v0.7.0 assertions: version, extraMounts, autoTrimMinutes, memoryPressureReclaim
expect(FirnVersion.current == "0.7.0", "Expected FirnVersion.current == 0.7.0, got \(FirnVersion.current)")
expect(defaultCfg.autoTrimMinutes == 60 && defaultCfg.extraMounts.isEmpty && defaultCfg.memoryPressureReclaim, "Expected default autoTrimMinutes=60, empty extraMounts, and memoryPressureReclaim=true")

var v07Cfg = FirnConfig()
v07Cfg.autoTrimMinutes = 15
v07Cfg.memoryPressureReclaim = false
v07Cfg.extraMounts = [FirnExtraMount(hostPath: "/tmp/firn-src", guestPath: "/mnt/src", readOnly: true)]
let tmpV07Dir = tmpStateDir.appendingPathComponent("v07")
try v07Cfg.save(to: tmpV07Dir)
let reloadedV07 = FirnConfig.load(from: tmpV07Dir)
expect(reloadedV07 == v07Cfg && reloadedV07.autoTrimMinutes == 15 && !reloadedV07.memoryPressureReclaim && reloadedV07.extraMounts.count == 1 && reloadedV07.extraMounts[0].readOnly, "v0.7.0 FirnConfig extraMounts/autoTrimMinutes/memoryPressureReclaim roundtrip failed")

print("FirnCoreCheck: all checks passed")
