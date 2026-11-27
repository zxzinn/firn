import AppKit
import Darwin
import Foundation
import FirnCore

private final class StatusActionBox: NSObject {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func trigger(_ sender: Any?) {
        handler()
    }
}

private final class SettingsWindowController: NSWindowController {
    private var cpusField: NSTextField!
    private var memoryField: NSTextField!
    private var idleField: NSTextField!
    private var domainField: NSTextField!
    private var exemptField: NSTextField!
    private var statusLabel: NSTextField!
    private let onSaved: () -> Void

    init(config: FirnConfig, onSaved: @escaping () -> Void) {
        self.onSaved = onSaved
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 270),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Firn Settings"
        window.center()
        super.init(window: window)
        buildUI(config: config)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI(config: FirnConfig) {
        guard let content = window?.contentView else { return }

        let labels = [
            "CPUs (restart required):",
            "Memory GiB (restart required):",
            "Idle Freeze Seconds (0 = off):",
            "Local Domain:",
            "Exempt Projects (comma):"
        ]
        let values = [
            String(config.cpus),
            String(config.memoryGiB),
            String(config.idleSeconds),
            config.domain,
            config.exemptProjects.joined(separator: ", ")
        ]

        var fields: [NSTextField] = []
        for idx in 0..<labels.count {
            let y = 216 - idx * 34
            let lbl = NSTextField(labelWithString: labels[idx])
            lbl.frame = NSRect(x: 20, y: y, width: 195, height: 22)
            lbl.alignment = .right
            content.addSubview(lbl)

            let tf = NSTextField(string: values[idx])
            tf.frame = NSRect(x: 224, y: y - 2, width: 176, height: 24)
            content.addSubview(tf)
            fields.append(tf)
        }
        cpusField = fields[0]
        memoryField = fields[1]
        idleField = fields[2]
        domainField = fields[3]
        exemptField = fields[4]

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 20, width: 280, height: 20)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        content.addSubview(statusLabel)

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 320, y: 14, width: 80, height: 30)
        content.addSubview(saveBtn)
    }

    @objc private func saveClicked() {
        var next = FirnConfig.load()
        if let v = Int(cpusField.stringValue), v > 0 { next.cpus = v }
        if let v = Int(memoryField.stringValue), v > 0 { next.memoryGiB = v }
        if let v = Int(idleField.stringValue), v >= 0 { next.idleSeconds = v }
        let dom = domainField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dom.isEmpty { next.domain = dom }
        next.exemptProjects = exemptField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let payload: [String: Any] = [
            "cpus": next.cpus,
            "memoryGiB": next.memoryGiB,
            "idleSeconds": next.idleSeconds,
            "domain": next.domain,
            "exemptProjects": next.exemptProjects,
        ]
        if FirnHostClient.isDaemonAlive(), let data = try? JSONSerialization.data(withJSONObject: payload) {
            if let resp = try? FirnHostClient.requestJSON(method: "POST", path: "/config", body: data, timeoutSeconds: 5) {
                let restart = (resp["restartRequired"] as? Bool) ?? false
                statusLabel.stringValue = restart ? "Saved (restart Firn VM to apply CPU/RAM)" : "Saved & applied live"
                onSaved()
                return
            }
        }
        do {
            try next.save()
            statusLabel.stringValue = "Saved to ~/.firn/config.json"
            onSaved()
        } catch {
            statusLabel.stringValue = "Error: \(error.localizedDescription)"
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var fallbackTimer: Timer?
    private var actionBoxes: [StatusActionBox] = []
    private var settingsController: SettingsWindowController?
    private var lastEventVersion: UInt64 = 0
    private var stopping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton(title: "Firn")
        rebuildMenu(statusPayload: nil, dnsPayload: nil)
        refreshStatus()
        startEventWatcher()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopping = true
    }

    private func configureButton(title: String) {
        guard let button = statusItem.button else { return }
        if let sym = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Firn") {
            sym.isTemplate = true
            button.image = sym
            button.imagePosition = .imageLeading
            button.title = " \(title)"
        } else {
            button.title = "❄︎ \(title)"
        }
    }

    private func startEventWatcher() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self, !self.stopping {
                if !FirnHostClient.isDaemonAlive() {
                    Thread.sleep(forTimeInterval: 1.5)
                    continue
                }
                if let resp = try? FirnHostClient.requestJSON(
                    method: "GET",
                    path: "/events?since=\(self.lastEventVersion)&wait=10",
                    timeoutSeconds: 15
                ), let v = (resp["version"] as? NSNumber)?.uint64Value {
                    if v != self.lastEventVersion {
                        self.lastEventVersion = v
                        self.refreshStatus()
                    }
                } else {
                    Thread.sleep(forTimeInterval: 1.0)
                }
            }
        }
    }

    private func refreshStatus() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = try? FirnHostClient.requestJSON(method: "GET", path: "/status", timeoutSeconds: 4)
            let dns = status != nil ? (try? FirnHostClient.requestJSON(method: "GET", path: "/dns", timeoutSeconds: 3)) : nil
            if let tv = (status?["topologyVersion"] as? NSNumber)?.uint64Value {
                self?.lastEventVersion = tv
            }
            DispatchQueue.main.async {
                self?.rebuildMenu(statusPayload: status, dnsPayload: dns)
            }
        }
    }

    private func addAction(_ title: String, to menu: NSMenu, keyEquivalent: String = "", handler: @escaping () -> Void) {
        let box = StatusActionBox(handler)
        actionBoxes.append(box)
        let item = NSMenuItem(title: title, action: #selector(StatusActionBox.trigger(_:)), keyEquivalent: keyEquivalent)
        item.target = box
        menu.addItem(item)
    }

    private func openSettingsWindow() {
        let cfg = FirnConfig.load()
        if let existing = settingsController {
            existing.close()
        }
        let ctrl = SettingsWindowController(config: cfg) { [weak self] in
            self?.refreshStatus()
        }
        settingsController = ctrl
        NSApplication.shared.activate(ignoringOtherApps: true)
        ctrl.showWindow(nil)
        ctrl.window?.makeKeyAndOrderFront(nil)
    }

    private func openLinuxShellInTerminal() {
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        let siblingCLI = bundleParent.appendingPathComponent("firn").path
        let cliCmd = FileManager.default.isExecutableFile(atPath: siblingCLI) ? siblingCLI : "firn"
        let script = "tell application \"Terminal\" to do script \"\(cliCmd) shell\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    private func rebuildMenu(statusPayload: [String: Any]?, dnsPayload: [String: Any]?) {
        actionBoxes.removeAll()
        let menu = NSMenu()

        guard let payload = statusPayload,
              let vmMem = payload["vmMemory"] as? [String: Any] else {
            configureButton(title: "Offline")
            let offlineItem = NSMenuItem(title: "Firn VM offline", action: nil, keyEquivalent: "")
            offlineItem.isEnabled = false
            menu.addItem(offlineItem)

            addAction("Start Firn VM (`firn up`)", to: menu) { [weak self] in
                DispatchQueue.global(qos: .userInitiated).async {
                    let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
                    let siblingCLI = bundleParent.appendingPathComponent("firn")
                    if FileManager.default.isExecutableFile(atPath: siblingCLI.path) {
                        let proc = Process()
                        proc.executableURL = siblingCLI
                        proc.arguments = ["up"]
                        try? proc.run()
                        proc.waitUntilExit()
                    }
                    self?.refreshStatus()
                }
            }
            addAction("Settings…", to: menu) { [weak self] in
                self?.openSettingsWindow()
            }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit Firn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem.menu = menu
            return
        }

        let total = (vmMem["totalBytes"] as? NSNumber)?.uint64Value ?? 0
        let avail = (vmMem["availableBytes"] as? NSNumber)?.uint64Value ?? 0
        let used = total > avail ? total - avail : 0
        let swapUsed = (vmMem["swapUsedBytes"] as? NSNumber)?.uint64Value ?? 0
        let balloonTarget = ((payload["balloon"] as? [String: Any])?["targetBytes"] as? NSNumber)?.uint64Value ?? total
        let hostMem = payload["hostMemory"] as? [String: Any]
        let hostFootprint = (hostMem?["footprintBytes"] as? NSNumber)?.uint64Value ?? 0
        let hostRSS = (hostMem?["rssBytes"] as? NSNumber)?.uint64Value ?? 0

        configureButton(title: FirnHostClient.formatBytes(hostFootprint > 0 ? hostFootprint : used))

        if hostFootprint > 0 {
            let hostLine = NSMenuItem(
                title: "Host Footprint: \(FirnHostClient.formatBytes(hostFootprint)) (RSS: \(FirnHostClient.formatBytes(hostRSS)))",
                action: nil,
                keyEquivalent: ""
            )
            hostLine.isEnabled = false
            menu.addItem(hostLine)
        }

        let vmLine = NSMenuItem(
            title: "Guest RAM: \(FirnHostClient.formatBytes(used)) / \(FirnHostClient.formatBytes(total))  (Balloon: \(FirnHostClient.formatBytes(balloonTarget)), Swap: \(FirnHostClient.formatBytes(swapUsed)))",
            action: nil,
            keyEquivalent: ""
        )
        vmLine.isEnabled = false
        menu.addItem(vmLine)

        if let disk = payload["disk"] as? [String: Any],
           let alloc = (disk["hostAllocatedBytes"] as? NSNumber)?.uint64Value,
           let logical = (disk["hostLogicalBytes"] as? NSNumber)?.uint64Value,
           logical > 0 {
            let diskItem = NSMenuItem(
                title: "APFS Disk: \(FirnHostClient.formatBytes(alloc)) / \(FirnHostClient.formatBytes(logical))",
                action: nil,
                keyEquivalent: ""
            )
            diskItem.isEnabled = false
            menu.addItem(diskItem)
        }

        let dnsObj = payload["dns"] as? [String: Any]
        let domain = (dnsObj?["domain"] as? String) ?? "firn.local"
        let dnsPort = (dnsObj?["dnsPort"] as? Int) ?? 53535
        let httpProxyPort = (dnsObj?["httpProxyPort"] as? Int) ?? 8088
        let httpsProxyPort = (dnsObj?["httpsProxyPort"] as? Int) ?? 8443
        let caTrusted = (dnsObj?["caTrusted"] as? Bool) ?? false
        let dnsItem = NSMenuItem(
            title: "DNS/Proxy: *.\(domain) (DNS :\(dnsPort), HTTP :\(httpProxyPort), HTTPS :\(httpsProxyPort)\(caTrusted ? ", CA ✓" : ""))",
            action: nil,
            keyEquivalent: ""
        )
        dnsItem.isEnabled = false
        menu.addItem(dnsItem)

        if let proxy = payload["proxy"] as? [String: Any] {
            let vpn = (proxy["vpnActive"] as? Bool) ?? false
            let httpP = (proxy["httpProxy"] as? String) ?? ""
            let sshActive = (proxy["sshAgentActive"] as? Bool) ?? false
            let base = vpn ? "Network: VPN + vsock netstack" : (httpP.isEmpty ? "Network: firn0 vsock netstack" : "Proxy Relay: \(httpP)")
            let proxyItem = NSMenuItem(title: "\(base)\(sshActive ? " + SSH Agent" : "")", action: nil, keyEquivalent: "")
            proxyItem.isEnabled = false
            menu.addItem(proxyItem)
        }

        addAction("Copy DOCKER_CONTEXT=\(FirnConfig.defaultDockerContext)", to: menu) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("DOCKER_CONTEXT=\(FirnConfig.defaultDockerContext)", forType: .string)
        }

        menu.addItem(.separator())

        let records = (dnsPayload?["records"] as? [[String: Any]]) ?? []
        let projects = (payload["projects"] as? [[String: Any]]) ?? []
        if projects.isEmpty {
            let empty = NSMenuItem(title: "No active stacks", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for proj in projects {
                let name = (proj["project"] as? String) ?? "unknown"
                let mem = (proj["memoryBytes"] as? NSNumber)?.uint64Value ?? 0
                let paused = ((proj["pausedCount"] as? Int) ?? 0) > 0
                let running = (proj["runningCount"] as? Int) ?? 0
                let exempt = (proj["exempt"] as? Bool) ?? false
                let stateTag = exempt ? "Exempt" : (paused ? "Frozen" : "Running(\(running))")

                let item = NSMenuItem(title: "\(name)  [\(stateTag)]  \(FirnHostClient.formatBytes(mem))", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                if paused {
                    addAction("Thaw Stack", to: sub) { [weak self] in
                        DispatchQueue.global(qos: .userInitiated).async {
                            _ = try? FirnHostClient.requestJSON(method: "POST", path: "/thaw/\(encoded)")
                            self?.refreshStatus()
                        }
                    }
                } else if running > 0 {
                    addAction("Freeze + Reclaim Memory", to: sub) { [weak self] in
                        DispatchQueue.global(qos: .userInitiated).async {
                            _ = try? FirnHostClient.requestJSON(method: "POST", path: "/freeze/\(encoded)?reclaim=1")
                            self?.refreshStatus()
                        }
                    }
                }

                let projHTTP = records.filter { rec in
                    (rec["project"] as? String) == name && ((rec["httpPort"] as? Int) ?? 0) > 0
                }
                if !projHTTP.isEmpty {
                    sub.addItem(.separator())
                    for rec in projHTTP {
                        let names = (rec["names"] as? [String]) ?? []
                        guard let fqdn = names.first(where: { $0.contains(".\(name).") }) ?? names.first else {
                            continue
                        }
                        if let httpsURL = URL(string: "https://\(fqdn):\(httpsProxyPort)/") {
                            addAction("Open https://\(fqdn):\(httpsProxyPort)", to: sub) {
                                NSWorkspace.shared.open(httpsURL)
                            }
                        }
                        if let httpURL = URL(string: "http://\(fqdn):\(httpProxyPort)/") {
                            addAction("Open http://\(fqdn):\(httpProxyPort)", to: sub) {
                                NSWorkspace.shared.open(httpURL)
                            }
                        }
                    }
                }

                item.submenu = sub
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        addAction("Open Linux Shell", to: menu) { [weak self] in
            self?.openLinuxShellInTerminal()
        }
        addAction("Trim Disk Space (fstrim)", to: menu) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = try? FirnHostClient.requestJSON(method: "POST", path: "/disk/trim", timeoutSeconds: 60)
                self?.refreshStatus()
            }
        }
        addAction("Shrink Memory Balloon Now", to: menu) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = try? FirnHostClient.requestJSON(method: "POST", path: "/balloon/shrink")
                self?.refreshStatus()
            }
        }
        addAction("Settings…", to: menu, keyEquivalent: ",") { [weak self] in
            self?.openSettingsWindow()
        }
        addAction("Stop Firn VM", to: menu) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = try? FirnHostClient.requestJSON(method: "POST", path: "/shutdown", timeoutSeconds: 5)
                self?.refreshStatus()
            }
        }
        menu.addItem(NSMenuItem(title: "Quit Firn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
}

signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)

private let app = NSApplication.shared
app.setActivationPolicy(.accessory)
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
