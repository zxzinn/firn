import Darwin
import Foundation

public enum FirnVersion {
    public static let current = "0.6.1"
    public static let githubRepo = "zxzinn/firn"

    public static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s = String(s.dropFirst())
        }
        return s
    }

    public static func normalizedTag(_ raw: String) -> String {
        let c = clean(raw)
        return c.isEmpty ? raw : "v\(c)"
    }

    private struct ParsedSemVer {
        let core: [Int]
        let pre: [String]
    }

    private static func parse(_ raw: String) -> ParsedSemVer {
        let cleaned = clean(raw)
        let buildStripped = cleaned.split(separator: "+", maxSplits: 1).first.map(String.init) ?? cleaned
        let parts = buildStripped.split(separator: "-", maxSplits: 1)
        let coreStr = String(parts.first ?? "")
        let preStr = parts.count > 1 ? String(parts[1]) : ""
        let coreNums = coreStr.split(separator: ".").map { Int($0) ?? 0 }
        let preParts = preStr.isEmpty ? [] : preStr.split(separator: ".").map(String.init)
        return ParsedSemVer(core: coreNums, pre: preParts)
    }

    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = parse(lhs)
        let b = parse(rhs)
        let n = max(a.core.count, b.core.count)
        for i in 0..<n {
            let av = i < a.core.count ? a.core[i] : 0
            let bv = i < b.core.count ? b.core[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        if a.pre.isEmpty && b.pre.isEmpty {
            return .orderedSame
        }
        if a.pre.isEmpty {
            return .orderedDescending
        }
        if b.pre.isEmpty {
            return .orderedAscending
        }
        let pn = max(a.pre.count, b.pre.count)
        for i in 0..<pn {
            if i >= a.pre.count { return .orderedAscending }
            if i >= b.pre.count { return .orderedDescending }
            let ap = a.pre[i]
            let bp = b.pre[i]
            if let ai = Int(ap), let bi = Int(bp) {
                if ai < bi { return .orderedAscending }
                if ai > bi { return .orderedDescending }
            } else {
                let cmp = ap.compare(bp)
                if cmp != .orderedSame { return cmp }
            }
        }
        return .orderedSame
    }
}

public enum FirnInstallOrigin: Equatable, Sendable {
    case homebrew(cellarPath: String)
    case standalone(binDir: URL)

    public static func detect(executablePath: String) -> FirnInstallOrigin {
        let resolved = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        let path = resolved.path
        for marker in ["/Cellar/firn/", "/opt/homebrew/Cellar/firn/", "/usr/local/Cellar/firn/"] {
            if let range = path.range(of: marker) {
                let tail = path[range.upperBound...]
                let end = tail.firstIndex(of: "/") ?? path.endIndex
                return .homebrew(cellarPath: String(path[..<end]))
            }
        }
        return .standalone(binDir: URL(fileURLWithPath: resolved.deletingLastPathComponent().path))
    }
}

public enum FirnDistribution {
    public static func parseSHA256Sums(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2 else { continue }
            let hash = String(parts[0]).lowercased()
            guard hash.count == 64 else { continue }
            var name = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") {
                name = String(name.dropFirst())
            }
            if name.hasPrefix("./") {
                name = String(name.dropFirst(2))
            }
            out[name] = hash
            if let base = name.split(separator: "/").last.map(String.init), !base.isEmpty {
                out[base] = hash
            }
        }
        return out
    }

    @discardableResult
    public static func ensureSparseDataDisk(at url: URL = FirnPaths.dataDiskURL, sizeGiB: UInt64 = 120) throws -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            return false
        }
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let tmp = parent.appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid())")
        let fd = Darwin.open(tmp.path, O_CREAT | O_RDWR | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed creating sparse disk \(tmp.path)"])
        }
        let targetBytes = off_t(sizeGiB) * 1024 * 1024 * 1024
        let truncRC = Darwin.ftruncate(fd, targetBytes)
        let closeErr = errno
        _ = Darwin.close(fd)
        if truncRC != 0 {
            try? fm.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(closeErr), userInfo: [NSLocalizedDescriptionKey: "Failed sizing sparse disk to \(sizeGiB) GiB"])
        }
        if Darwin.rename(tmp.path, url.path) != 0 {
            let e = errno
            try? fm.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e), userInfo: [NSLocalizedDescriptionKey: "Failed moving sparse disk into \(url.path)"])
        }
        return true
    }

    public static func missingGuestImages(in imagesDir: URL = FirnPaths.imagesDir) -> [URL] {
        let required = [
            imagesDir.appendingPathComponent("vmlinux.Image"),
            imagesDir.appendingPathComponent("initramfs.img"),
            imagesDir.appendingPathComponent("rootfs.ext4"),
        ]
        let fm = FileManager.default
        return required.filter { !fm.fileExists(atPath: $0.path) }
    }

    public static func installedImageVersion(in imagesDir: URL = FirnPaths.imagesDir) -> String? {
        let url = imagesDir.appendingPathComponent("version.txt")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func recordInstalledImageVersion(_ version: String, in imagesDir: URL = FirnPaths.imagesDir) throws {
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let url = imagesDir.appendingPathComponent("version.txt")
        let clean = version.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try Data(clean.utf8).write(to: url, options: .atomic)
    }

    public static func fetchLatestGitHubRelease(repo: String = FirnVersion.githubRepo, timeoutSeconds: Double = 6.0) -> (tagName: String, htmlURL: String)? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSeconds)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Firn/\(FirnVersion.current)", forHTTPHeaderField: "User-Agent")
        if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ?? ProcessInfo.processInfo.environment["GH_TOKEN"], !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let sem = DispatchSemaphore(value: 0)
        var out: (String, String)?
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            guard err == nil,
                  let http = resp as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                return
            }
            let html = (obj["html_url"] as? String) ?? "https://github.com/\(repo)/releases/tag/\(tag)"
            out = (tag, html)
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeoutSeconds + 0.5)
        return out
    }
}
