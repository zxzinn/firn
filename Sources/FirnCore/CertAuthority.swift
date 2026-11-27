import Darwin
import Foundation
import Security

public struct CATrustStatus: Sendable, Equatable {
    public var exists: Bool
    public var trusted: Bool
    public var certPath: String
    public var fingerprint: String
}

public enum CertAuthority {
    private static let openSSLPath = "/usr/bin/openssl"
    private static let securityPath = "/usr/bin/security"
    private static let pkcs12Password = "firn"

    private static func runTool(_ executable: String, _ args: [String]) throws -> (code: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        var outData = Data()
        var errData = Data()
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
        proc.waitUntilExit()
        return (
            proc.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    public static func sanitizeDNSLabel(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = ""
        for ch in lowered {
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") || ch == "-" {
                out.append(ch)
            } else if ch == "_" || ch == "." || ch == " " {
                out.append("-")
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    @discardableResult
    public static func ensureCA(in certsDir: URL = FirnPaths.certsDir) throws -> (certURL: URL, keyURL: URL) {
        let fm = FileManager.default
        try fm.createDirectory(at: certsDir, withIntermediateDirectories: true)
        let certURL = certsDir.appendingPathComponent("ca.crt")
        let keyURL = certsDir.appendingPathComponent("ca.key")
        if fm.fileExists(atPath: certURL.path) && fm.fileExists(atPath: keyURL.path) {
            return (certURL, keyURL)
        }

        let cfgURL = certsDir.appendingPathComponent(".ca-openssl.cnf")
        let cfg = """
        [req]
        distinguished_name = dn
        x509_extensions = v3_ca
        prompt = no

        [dn]
        CN = Firn Local Development CA
        O = Firn

        [v3_ca]
        basicConstraints = critical, CA:TRUE
        keyUsage = critical, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        """
        try cfg.write(to: cfgURL, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: cfgURL) }

        let keyGen = try runTool(openSSLPath, [
            "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", keyURL.path
        ])
        guard keyGen.code == 0 else {
            throw NSError(domain: "FirnCA", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed generating CA key: \(keyGen.stderr)"])
        }
        chmod(keyURL.path, 0o600)

        let certGen = try runTool(openSSLPath, [
            "req", "-new", "-x509", "-sha256",
            "-key", keyURL.path,
            "-days", "3650",
            "-config", cfgURL.path,
            "-extensions", "v3_ca",
            "-out", certURL.path
        ])
        guard certGen.code == 0 else {
            throw NSError(domain: "FirnCA", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed generating CA certificate: \(certGen.stderr)"])
        }
        return (certURL, keyURL)
    }

    public static func ensureServerIdentity(
        domain: String,
        projects: [String],
        in certsDir: URL = FirnPaths.certsDir
    ) throws -> SecIdentity {
        let fm = FileManager.default
        let (caCertURL, caKeyURL) = try ensureCA(in: certsDir)
        let leafDir = certsDir.appendingPathComponent("leaves")
        try fm.createDirectory(at: leafDir, withIntermediateDirectories: true)

        let cleanDomain = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        var altNames = [
            "DNS:\(cleanDomain)",
            "DNS:*.\(cleanDomain)"
        ]
        var uniqueProjects: [String] = []
        for rawProj in Set(projects) {
            let label = sanitizeDNSLabel(rawProj)
            if !label.isEmpty {
                uniqueProjects.append(label)
            }
        }
        uniqueProjects.sort()
        for proj in uniqueProjects {
            altNames.append("DNS:*.\(proj).\(cleanDomain)")
        }

        let specKey = altNames.joined(separator: ",")
        let hashHex = specKey.utf8.reduce(UInt64(1469598103934665603)) { acc, b in
            (acc ^ UInt64(b)) &* 1099511628211
        }
        let stem = "\(cleanDomain)-\(String(hashHex, radix: 16))"
        let leafKeyURL = leafDir.appendingPathComponent("\(stem).key")
        let leafCertURL = leafDir.appendingPathComponent("\(stem).crt")
        let leafP12URL = leafDir.appendingPathComponent("\(stem).p12")

        if !fm.fileExists(atPath: leafP12URL.path) {
            let csrURL = leafDir.appendingPathComponent("\(stem).csr")
            let extURL = leafDir.appendingPathComponent("\(stem).ext")
            let srlURL = certsDir.appendingPathComponent("ca.srl")
            defer {
                try? fm.removeItem(at: csrURL)
                try? fm.removeItem(at: extURL)
            }

            let keyRes = try runTool(openSSLPath, [
                "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", leafKeyURL.path
            ])
            guard keyRes.code == 0 else {
                throw NSError(domain: "FirnCA", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed generating leaf key: \(keyRes.stderr)"])
            }
            chmod(leafKeyURL.path, 0o600)

            let csrRes = try runTool(openSSLPath, [
                "req", "-new",
                "-key", leafKeyURL.path,
                "-subj", "/CN=*.\(cleanDomain)/O=Firn",
                "-out", csrURL.path
            ])
            guard csrRes.code == 0 else {
                throw NSError(domain: "FirnCA", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed generating leaf CSR: \(csrRes.stderr)"])
            }

            let extBody = """
            basicConstraints = CA:FALSE
            keyUsage = critical, digitalSignature, keyEncipherment
            extendedKeyUsage = serverAuth
            subjectKeyIdentifier = hash
            authorityKeyIdentifier = keyid,issuer
            subjectAltName = \(specKey)
            """
            try extBody.write(to: extURL, atomically: true, encoding: .utf8)

            let signRes = try runTool(openSSLPath, [
                "x509", "-req", "-sha256",
                "-in", csrURL.path,
                "-CA", caCertURL.path,
                "-CAkey", caKeyURL.path,
                "-CAcreateserial",
                "-CAserial", srlURL.path,
                "-days", "825",
                "-extfile", extURL.path,
                "-out", leafCertURL.path
            ])
            guard signRes.code == 0 else {
                throw NSError(domain: "FirnCA", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed signing leaf cert: \(signRes.stderr)"])
            }

            let p12Res = try runTool(openSSLPath, [
                "pkcs12", "-export",
                "-inkey", leafKeyURL.path,
                "-in", leafCertURL.path,
                "-certfile", caCertURL.path,
                "-passout", "pass:\(pkcs12Password)",
                "-out", leafP12URL.path
            ])
            guard p12Res.code == 0 else {
                throw NSError(domain: "FirnCA", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed exporting PKCS#12: \(p12Res.stderr)"])
            }
            chmod(leafP12URL.path, 0o600)
        }

        let p12Data = try Data(contentsOf: leafP12URL)
        let options = [kSecImportExportPassphrase as String: pkcs12Password] as CFDictionary
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identityAny = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: "FirnCA", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "SecPKCS12Import failed with status \(status)"])
        }
        let identity = identityAny as! SecIdentity
        return identity
    }

    public static func caTrustStatus(in certsDir: URL = FirnPaths.certsDir) -> CATrustStatus {
        let certURL = certsDir.appendingPathComponent("ca.crt")
        let exists = FileManager.default.fileExists(atPath: certURL.path)
        guard exists else {
            return CATrustStatus(exists: false, trusted: false, certPath: certURL.path, fingerprint: "")
        }
        var fp = ""
        if let fpRes = try? runTool(openSSLPath, ["x509", "-in", certURL.path, "-noout", "-fingerprint", "-sha256"]),
           fpRes.code == 0 {
            fp = fpRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let verify = try? runTool(securityPath, ["verify-cert", "-c", certURL.path, "-L"])
        let trusted = (verify?.code == 0)
        return CATrustStatus(exists: true, trusted: trusted, certPath: certURL.path, fingerprint: fp)
    }

    public static func pfAnchorContents(httpPort: UInt16, httpsPort: UInt16) -> String {
        """
        # Generated by Firn for zero-port http/https://*.firn.local access
        rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port \(httpPort)
        rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port \(httpsPort)
        rdr pass on lo0 inet6 proto tcp from any to ::1 port 80 -> ::1 port \(httpPort)
        rdr pass on lo0 inet6 proto tcp from any to ::1 port 443 -> ::1 port \(httpsPort)
        """
    }
}
