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

private struct MetricSample {
    let footprintMiB: Double
    let cpuPercent: Double
}

private final class MetricsSparklineView: NSView {
    private var samples: [MetricSample] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: 68)
    }

    func update(samples: [MetricSample]) {
        self.samples = samples
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let padX: CGFloat = 14
        let padY: CGFloat = 6
        let gap: CGFloat = 10
        let cardW = (bounds.width - padX * 2 - gap) / 2.0
        let cardH = bounds.height - padY * 2

        let leftRect = NSRect(x: padX, y: padY, width: cardW, height: cardH)
        let rightRect = NSRect(x: padX + cardW + gap, y: padY, width: cardW, height: cardH)

        let latestMem = samples.last?.footprintMiB ?? 0
        let latestCPU = samples.last?.cpuPercent ?? 0

        drawSparkCard(
            in: leftRect,
            title: String(format: "Footprint %.0f MiB", latestMem),
            values: samples.map { $0.footprintMiB },
            minUpperBound: 64.0,
            color: NSColor.controlAccentColor
        )
        drawSparkCard(
            in: rightRect,
            title: String(format: "Host CPU %.1f%%", latestCPU),
            values: samples.map { $0.cpuPercent },
            minUpperBound: 25.0,
            color: NSColor.systemTeal
        )
    }

    private func drawSparkCard(
        in rect: NSRect,
        title: String,
        values: [Double],
        minUpperBound: Double,
        color: NSColor
    ) {
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.16).setFill()
        bgPath.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let label = NSString(string: title)
        label.draw(at: NSPoint(x: rect.minX + 7, y: rect.maxY - 16), withAttributes: attrs)

        let plotRect = NSRect(
            x: rect.minX + 6,
            y: rect.minY + 5,
            width: rect.width - 12,
            height: max(8, rect.height - 24)
        )
        guard !values.isEmpty else { return }

        let maxVal = max(minUpperBound, (values.max() ?? 0) * 1.15)
        let pts: [NSPoint]
        if values.count == 1 {
            let y = plotRect.minY + CGFloat(min(1.0, max(0.0, values[0] / maxVal))) * plotRect.height
            pts = [NSPoint(x: plotRect.minX, y: y), NSPoint(x: plotRect.maxX, y: y)]
        } else {
            let stepX = plotRect.width / CGFloat(values.count - 1)
            pts = values.enumerated().map { idx, val in
                let norm = min(1.0, max(0.0, val / maxVal))
                return NSPoint(
                    x: plotRect.minX + CGFloat(idx) * stepX,
                    y: plotRect.minY + CGFloat(norm) * plotRect.height
                )
            }
        }

        let fillPath = NSBezierPath()
        fillPath.move(to: NSPoint(x: pts[0].x, y: plotRect.minY))
        for pt in pts {
            fillPath.line(to: pt)
        }
        fillPath.line(to: NSPoint(x: pts[pts.count - 1].x, y: plotRect.minY))
        fillPath.close()
        color.withAlphaComponent(0.22).setFill()
        fillPath.fill()

        let strokePath = NSBezierPath()
        strokePath.lineWidth = 1.5
        strokePath.lineJoinStyle = .round
        strokePath.lineCapStyle = .round
        strokePath.move(to: pts[0])
        for pt in pts.dropFirst() {
            strokePath.line(to: pt)
        }
        color.setStroke()
        strokePath.stroke()
    }
}

private final class ContainerLogsWindowController: NSWindowController, NSWindowDelegate {
    private var textView: NSTextView!
    private var statusField: NSTextField!
    private var stopButton: NSButton!
    private var proc: Process?
    private var outPipe: Pipe?
    private let onClose: (ContainerLogsWindowController) -> Void
    private var stopping = false

    init(title: String, dockerArgs: [String], onClose: @escaping (ContainerLogsWindowController) -> Void) {
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = NSSize(width: 480, height: 300)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        startStream(dockerArgs: dockerArgs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 44, width: 676, height: 404))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 676, height: 404))
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.textColor = NSColor.textColor
        tv.autoresizingMask = [.width]
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv
        content.addSubview(scroll)
        textView = tv

        statusField = NSTextField(labelWithString: "Streaming…")
        statusField.frame = NSRect(x: 14, y: 12, width: 320, height: 20)
        statusField.font = NSFont.systemFont(ofSize: 11)
        statusField.textColor = NSColor.secondaryLabelColor
        statusField.autoresizingMask = [.maxXMargin, .maxYMargin]
        content.addSubview(statusField)

        let clearBtn = NSButton(title: "Clear", target: self, action: #selector(clearClicked))
        clearBtn.bezelStyle = .rounded
        clearBtn.frame = NSRect(x: 452, y: 8, width: 72, height: 28)
        clearBtn.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(clearBtn)

        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyClicked))
        copyBtn.bezelStyle = .rounded
        copyBtn.frame = NSRect(x: 530, y: 8, width: 72, height: 28)
        copyBtn.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(copyBtn)

        stopButton = NSButton(title: "Stop", target: self, action: #selector(stopClicked))
        stopButton.bezelStyle = .rounded
        stopButton.frame = NSRect(x: 608, y: 8, width: 80, height: 28)
        stopButton.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(stopButton)
    }

    private func resolveDockerExecutable() -> String {
        for path in ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "/usr/bin/env"
    }

    private func startStream(dockerArgs: [String]) {
        let exe = resolveDockerExecutable()
        let finalArgs = exe == "/usr/bin/env" ? ["docker"] + dockerArgs : dockerArgs
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = finalArgs

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            if let chunk = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
                DispatchQueue.main.async {
                    self?.appendLogText(chunk)
                }
            }
        }

        p.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.statusField?.stringValue = "Stream ended (exit \(finished.terminationStatus))"
                self?.stopButton?.isEnabled = false
            }
        }

        do {
            try p.run()
            self.proc = p
            self.outPipe = pipe
        } catch {
            appendLogText("Failed to launch docker logs: \(error.localizedDescription)\n")
            statusField.stringValue = "Error"
            stopButton.isEnabled = false
        }
    }

    private func appendLogText(_ chunk: String) {
        guard let tv = textView else { return }
        let storage = tv.textStorage
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
        storage?.append(NSAttributedString(string: chunk, attributes: attrs))
        let maxChars = 200_000
        if let len = storage?.length, len > maxChars {
            storage?.deleteCharacters(in: NSRange(location: 0, length: len - maxChars))
        }
        tv.scrollToEndOfDocument(nil)
    }

    func stopStreaming() {
        stopping = true
        outPipe?.fileHandleForReading.readabilityHandler = nil
        if let p = proc, p.isRunning {
            p.terminate()
        }
        proc = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopStreaming()
        onClose(self)
    }

    @objc private func clearClicked() {
        textView.string = ""
    }

    @objc private func copyClicked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc private func stopClicked() {
        stopStreaming()
        statusField.stringValue = "Stopped"
        stopButton.isEnabled = false
    }
}

private final class SettingsWindowController: NSWindowController {
    private var cpusField: NSTextField!
    private var memoryField: NSTextField!
    private var idleField: NSTextField!
    private var hibernateField: NSTextField!
    private var domainField: NSTextField!
    private var exemptField: NSTextField!
    private var diskSyncPopup: NSPopUpButton!
    private var fsModePopup: NSPopUpButton!
    private var nestedVirtCheck: NSButton!
    private var directRouteDNSCheck: NSButton!
    private var statusLabel: NSTextField!
    private let onSaved: () -> Void

    init(config: FirnConfig, onSaved: @escaping () -> Void) {
        self.onSaved = onSaved
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 424),
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
            "Auto-Hibernate Seconds (0 = off):",
            "Local Domain:",
            "Exempt Projects (comma):"
        ]
        let values = [
            String(config.cpus),
            String(config.memoryGiB),
            String(config.idleSeconds),
            String(config.hibernateSeconds),
            config.domain,
            config.exemptProjects.joined(separator: ", ")
        ]

        var fields: [NSTextField] = []
        var y = 376
        for idx in 0..<labels.count {
            let lbl = NSTextField(labelWithString: labels[idx])
            lbl.frame = NSRect(x: 20, y: y, width: 215, height: 22)
            lbl.alignment = .right
            content.addSubview(lbl)

            let tf = NSTextField(string: values[idx])
            tf.frame = NSRect(x: 244, y: y - 2, width: 196, height: 24)
            content.addSubview(tf)
            fields.append(tf)
            y -= 34
        }
        cpusField = fields[0]
        memoryField = fields[1]
        idleField = fields[2]
        hibernateField = fields[3]
        domainField = fields[4]
        exemptField = fields[5]

        let syncLbl = NSTextField(labelWithString: "Disk Sync Mode (restart):")
        syncLbl.frame = NSRect(x: 20, y: y, width: 215, height: 22)
        syncLbl.alignment = .right
        content.addSubview(syncLbl)
        diskSyncPopup = NSPopUpButton(frame: NSRect(x: 242, y: y - 3, width: 198, height: 26), pullsDown: false)
        diskSyncPopup.addItems(withTitles: ["none", "fsync"])
        diskSyncPopup.selectItem(withTitle: config.diskSyncMode)
        content.addSubview(diskSyncPopup)
        y -= 34

        let fsLbl = NSTextField(labelWithString: "Host Filesystem (restart):")
        fsLbl.frame = NSRect(x: 20, y: y, width: 215, height: 22)
        fsLbl.alignment = .right
        content.addSubview(fsLbl)
        fsModePopup = NSPopUpButton(frame: NSRect(x: 242, y: y - 3, width: 198, height: 26), pullsDown: false)
        fsModePopup.addItems(withTitles: ["firnfs", "virtiofs"])
        fsModePopup.selectItem(withTitle: config.fsMode)
        content.addSubview(fsModePopup)
        y -= 34

        nestedVirtCheck = NSButton(checkboxWithTitle: "Nested Virtualization (/dev/kvm, restart)", target: nil, action: nil)
        nestedVirtCheck.frame = NSRect(x: 242, y: y, width: 210, height: 22)
        nestedVirtCheck.state = config.nestedVirtualization ? .on : .off
        content.addSubview(nestedVirtCheck)
        y -= 28

        directRouteDNSCheck = NSButton(checkboxWithTitle: "Direct Container IP DNS (utun)", target: nil, action: nil)
        directRouteDNSCheck.frame = NSRect(x: 242, y: y, width: 210, height: 22)
        directRouteDNSCheck.state = config.directRouteDNS ? .on : .off
        content.addSubview(directRouteDNSCheck)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 20, width: 320, height: 20)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        content.addSubview(statusLabel)

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 360, y: 14, width: 80, height: 30)
        content.addSubview(saveBtn)
    }

    @objc private func saveClicked() {
        var next = FirnConfig.load()
        if let v = Int(cpusField.stringValue), v > 0 { next.cpus = v }
        if let v = Int(memoryField.stringValue), v > 0 { next.memoryGiB = v }
        if let v = Int(idleField.stringValue), v >= 0 { next.idleSeconds = v }
        if let v = Int(hibernateField.stringValue), v >= 0 { next.hibernateSeconds = v }
        let dom = domainField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dom.isEmpty { next.domain = dom }
        next.exemptProjects = exemptField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let dsm = diskSyncPopup.selectedItem?.title, dsm == "none" || dsm == "fsync" {
            next.diskSyncMode = dsm
        }
        if let fsm = fsModePopup.selectedItem?.title, fsm == "firnfs" || fsm == "virtiofs" {
            next.fsMode = fsm
        }
        next.nestedVirtualization = (nestedVirtCheck.state == .on)
        next.directRouteDNS = (directRouteDNSCheck.state == .on)

        let payload: [String: Any] = [
            "cpus": next.cpus,
            "memoryGiB": next.memoryGiB,
            "idleSeconds": next.idleSeconds,
            "hibernateSeconds": next.hibernateSeconds,
            "domain": next.domain,
            "exemptProjects": next.exemptProjects,
            "diskSyncMode": next.diskSyncMode,
            "fsMode": next.fsMode,
            "nestedVirtualization": next.nestedVirtualization,
            "directRouteDNS": next.directRouteDNS,
        ]
        if FirnHostClient.isDaemonAlive(), let data = try? JSONSerialization.data(withJSONObject: payload) {
            if let resp = try? FirnHostClient.requestJSON(method: "POST", path: "/config", body: data, timeoutSeconds: 5) {
                let restart = (resp["restartRequired"] as? Bool) ?? false
                statusLabel.stringValue = restart ? "Saved (restart Firn VM to apply VM settings)" : "Saved & applied live"
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
    private var logControllers: [ContainerLogsWindowController] = []
    private var metricSamples: [MetricSample] = []
    private var lastEventVersion: UInt64 = 0
    private var availableUpdateTag: String?
    private var updateCheckNote: String?
    private var latestStatusPayload: [String: Any]?
    private var latestDNSPayload: [String: Any]?
    private var latestK8sPayload: [String: Any]?
    private var latestMachinesPayload: [String: Any]?
    private var stopping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton(title: "Firn")
        rebuildMenu(statusPayload: nil, dnsPayload: nil, k8sPayload: nil, machinesPayload: nil)
        refreshStatus()
        startEventWatcher()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.checkForUpdates(userInitiated: false)
        }
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopping = true
        for ctrl in logControllers {
            ctrl.stopStreaming()
            ctrl.close()
        }
        logControllers.removeAll()
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
            let hibernated = (status?["hibernated"] as? Bool) ?? false
            let dns = (status != nil && !hibernated) ? (try? FirnHostClient.requestJSON(method: "GET", path: "/dns", timeoutSeconds: 3)) : nil
            let k8s = (status != nil && !hibernated) ? (try? FirnHostClient.requestJSON(method: "GET", path: "/k8s/status", timeoutSeconds: 3)) : nil
            let machines = (status != nil && !hibernated) ? (try? FirnHostClient.requestJSON(method: "GET", path: "/machines", timeoutSeconds: 3)) : nil

            if let tv = (status?["topologyVersion"] as? NSNumber)?.uint64Value {
                self?.lastEventVersion = tv
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.latestStatusPayload = status
                self.latestDNSPayload = dns
                self.latestK8sPayload = k8s
                self.latestMachinesPayload = machines
                if let hostMem = status?["hostMemory"] as? [String: Any] {
                    let fpBytes = (hostMem["footprintBytes"] as? NSNumber)?.doubleValue ?? 0
                    let cpu = (hostMem["cpuPercent"] as? NSNumber)?.doubleValue ?? 0
                    self.metricSamples.append(MetricSample(footprintMiB: fpBytes / (1024.0 * 1024.0), cpuPercent: cpu))
                    if self.metricSamples.count > 60 {
                        self.metricSamples.removeFirst(self.metricSamples.count - 60)
                    }
                }
                self.rebuildMenu(statusPayload: status, dnsPayload: dns, k8sPayload: k8s, machinesPayload: machines)
            }
        }
    }

    private func checkForUpdates(userInitiated: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rel = FirnDistribution.fetchLatestGitHubRelease()
            DispatchQueue.main.async {
                guard let self else { return }
                if let rel {
                    if FirnVersion.compare(FirnVersion.current, rel.tagName) == .orderedAscending {
                        self.availableUpdateTag = rel.tagName
                        self.updateCheckNote = "Update available: \(rel.tagName)"
                    } else {
                        self.availableUpdateTag = nil
                        if userInitiated {
                            self.updateCheckNote = "Up to date (v\(FirnVersion.current))"
                        }
                    }
                } else if userInitiated {
                    self.updateCheckNote = "Update check unavailable offline"
                }
                self.rebuildMenu(
                    statusPayload: self.latestStatusPayload,
                    dnsPayload: self.latestDNSPayload,
                    k8sPayload: self.latestK8sPayload,
                    machinesPayload: self.latestMachinesPayload
                )
            }
        }
    }

    private func appendVersionAndUpdateItems(to menu: NSMenu) {
        if let tag = availableUpdateTag {
            addAction("Update Available: \(tag) (`firn upgrade`)", to: menu) { [weak self] in
                self?.openShellInTerminal(args: ["upgrade"])
            }
        } else if let note = updateCheckNote {
            let noteItem = NSMenuItem(title: note, action: nil, keyEquivalent: "")
            noteItem.isEnabled = false
            menu.addItem(noteItem)
        }
        addAction("Check for Updates… (v\(FirnVersion.current))", to: menu) { [weak self] in
            self?.checkForUpdates(userInitiated: true)
        }
    }

    private func addAction(_ title: String, to menu: NSMenu, keyEquivalent: String = "", handler: @escaping () -> Void) {
        let box = StatusActionBox(handler)
        actionBoxes.append(box)
        let item = NSMenuItem(title: title, action: #selector(StatusActionBox.trigger(_:)), keyEquivalent: keyEquivalent)
        item.target = box
        menu.addItem(item)
    }

    private func siblingCLIExecutable() -> String {
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        let siblingCLI = bundleParent.appendingPathComponent("firn").path
        return FileManager.default.isExecutableFile(atPath: siblingCLI) ? siblingCLI : "firn"
    }

    private func runCLIAction(_ args: [String]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cli = self?.siblingCLIExecutable() ?? "firn"
            let proc = Process()
            if cli == "firn" {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                proc.arguments = ["firn"] + args
            } else {
                proc.executableURL = URL(fileURLWithPath: cli)
                proc.arguments = args
            }
            try? proc.run()
            proc.waitUntilExit()
            self?.refreshStatus()
        }
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

    private func openLogsWindow(title: String, dockerArgs: [String]) {
        let ctrl = ContainerLogsWindowController(title: title, dockerArgs: dockerArgs) { [weak self] closed in
            self?.logControllers.removeAll { $0 === closed }
        }
        logControllers.append(ctrl)
        NSApplication.shared.activate(ignoringOtherApps: true)
        ctrl.showWindow(nil)
        ctrl.window?.makeKeyAndOrderFront(nil)
    }

    private func openShellInTerminal(args: [String]) {
        let cliCmd = siblingCLIExecutable()
        let quotedArgs = args.map { arg -> String in
            "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
        let script = "tell application \"Terminal\" to do script \"'\(cliCmd)' \(quotedArgs)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    private func appendSparklineItem(to menu: NSMenu) {
        let sparkView = MetricsSparklineView(frame: NSRect(x: 0, y: 0, width: 320, height: 68))
        sparkView.update(samples: metricSamples)
        let sparkItem = NSMenuItem()
        sparkItem.view = sparkView
        menu.addItem(sparkItem)
    }

    private func rebuildMenu(
        statusPayload: [String: Any]?,
        dnsPayload: [String: Any]?,
        k8sPayload: [String: Any]?,
        machinesPayload: [String: Any]?
    ) {
        actionBoxes.removeAll()
        let menu = NSMenu()

        guard let payload = statusPayload else {
            configureButton(title: "Offline")
            let offlineItem = NSMenuItem(title: "Firn VM offline", action: nil, keyEquivalent: "")
            offlineItem.isEnabled = false
            menu.addItem(offlineItem)

            addAction("Start Firn VM (`firn up`)", to: menu) { [weak self] in
                self?.runCLIAction(["up"])
            }
            addAction("Settings…", to: menu, keyEquivalent: ",") { [weak self] in
                self?.openSettingsWindow()
            }
            appendVersionAndUpdateItems(to: menu)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit Firn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem.menu = menu
            return
        }

        let hibernated = (payload["hibernated"] as? Bool) ?? false
        let hostMem = payload["hostMemory"] as? [String: Any]
        let hostFootprint = (hostMem?["footprintBytes"] as? NSNumber)?.uint64Value ?? 0
        let hostRSS = (hostMem?["rssBytes"] as? NSNumber)?.uint64Value ?? 0
        let cpuPct = (hostMem?["cpuPercent"] as? NSNumber)?.doubleValue ?? 0

        if hibernated {
            configureButton(title: "Hibernated")
            if !metricSamples.isEmpty {
                appendSparklineItem(to: menu)
            }
            let mode = (payload["hibernateMode"] as? String) ?? "snapshot"
            let diskObj = payload["disk"] as? [String: Any]
            let saved = (diskObj?["savedStateBytes"] as? NSNumber)?.uint64Value ?? 0
            let hibLine = NSMenuItem(
                title: "VM Hibernated (mode=\(mode), saved=\(FirnHostClient.formatBytes(saved)))",
                action: nil,
                keyEquivalent: ""
            )
            hibLine.isEnabled = false
            menu.addItem(hibLine)

            let hostLine = NSMenuItem(
                title: "Host Footprint: \(FirnHostClient.formatBytes(hostFootprint)) (0 MiB VM XPC)",
                action: nil,
                keyEquivalent: ""
            )
            hostLine.isEnabled = false
            menu.addItem(hostLine)

            menu.addItem(.separator())
            addAction("Resume Firn VM", to: menu) { [weak self] in
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = try? FirnHostClient.requestJSON(method: "POST", path: "/resume", timeoutSeconds: 120)
                    self?.refreshStatus()
                }
            }
            addAction("Settings…", to: menu, keyEquivalent: ",") { [weak self] in
                self?.openSettingsWindow()
            }
            addAction("Stop Firn Daemon", to: menu) { [weak self] in
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = try? FirnHostClient.requestJSON(method: "POST", path: "/shutdown", timeoutSeconds: 5)
                    self?.refreshStatus()
                }
            }
            appendVersionAndUpdateItems(to: menu)
            menu.addItem(NSMenuItem(title: "Quit Firn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem.menu = menu
            return
        }

        let vmMem = (payload["vmMemory"] as? [String: Any]) ?? [:]
        let total = (vmMem["totalBytes"] as? NSNumber)?.uint64Value ?? 0
        let avail = (vmMem["availableBytes"] as? NSNumber)?.uint64Value ?? 0
        let used = total > avail ? total - avail : 0
        let swapUsed = (vmMem["swapUsedBytes"] as? NSNumber)?.uint64Value ?? 0
        let balloonTarget = ((payload["balloon"] as? [String: Any])?["targetBytes"] as? NSNumber)?.uint64Value ?? total

        configureButton(title: FirnHostClient.formatBytes(hostFootprint > 0 ? hostFootprint : used))
        appendSparklineItem(to: menu)

        if hostFootprint > 0 {
            let hostLine = NSMenuItem(
                title: String(format: "Host Footprint: %@ (RSS: %@, CPU: %.1f%%)", FirnHostClient.formatBytes(hostFootprint), FirnHostClient.formatBytes(hostRSS), cpuPct),
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

        let caps = (payload["capabilities"] as? [String: Any]) ?? [:]
        let routeObj = (payload["route"] as? [String: Any]) ?? [:]
        var capBadges: [String] = [
            ((caps["firnfsActive"] as? Bool) ?? false) ? "firnfs" : "virtiofs",
            ((caps["fastVirtioNet"] as? Bool) ?? false) ? "jumbo-16k" : "nat",
        ]
        if (caps["nestedKvm"] as? Bool) ?? false { capBadges.append("KVM ✓") }
        if (routeObj["utunConnected"] as? Bool) ?? false { capBadges.append("utun ✓") }
        if (caps["gpuDri"] as? Bool) ?? false { capBadges.append("GPU ✓") }
        if (caps["k3sRunning"] as? Bool) ?? false { capBadges.append("k3s ✓") }
        let capItem = NSMenuItem(title: "Engine: " + capBadges.joined(separator: " • "), action: nil, keyEquivalent: "")
        capItem.isEnabled = false
        menu.addItem(capItem)

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
            let base = vpn ? "Network: VPN + firn-hostnet" : (httpP.isEmpty ? "Network: firn-hostnet L2/L3" : "Proxy Relay: \(httpP)")
            let proxyItem = NSMenuItem(title: "\(base)\(sshActive ? " + SSH Agent" : "")", action: nil, keyEquivalent: "")
            proxyItem.isEnabled = false
            menu.addItem(proxyItem)
        }

        addAction("Copy DOCKER_CONTEXT=\(FirnConfig.defaultDockerContext)", to: menu) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("DOCKER_CONTEXT=\(FirnConfig.defaultDockerContext)", forType: .string)
        }

        menu.addItem(.separator())

        // Kubernetes (k3s) submenu
        let k8sRunning = (k8sPayload?["running"] as? Bool) ?? ((caps["k3sRunning"] as? Bool) ?? false)
        let k8sReady = (k8sPayload?["ready"] as? Bool) ?? false
        let k8sFrozen = (k8sPayload?["frozen"] as? Bool) ?? false
        let k8sVer = (k8sPayload?["version"] as? String) ?? "k3s"
        let k8sStateLabel = k8sFrozen ? "Frozen" : (k8sReady ? "Ready" : (k8sRunning ? "Starting" : "Off"))
        let k8sItem = NSMenuItem(title: "Kubernetes (\(k8sVer))  [\(k8sStateLabel)]", action: nil, keyEquivalent: "")
        let k8sSub = NSMenu()
        if let k8sMem = (k8sPayload?["memoryBytes"] as? NSNumber)?.uint64Value, k8sMem > 0 {
            let mItem = NSMenuItem(title: "Cluster Memory: \(FirnHostClient.formatBytes(k8sMem))", action: nil, keyEquivalent: "")
            mItem.isEnabled = false
            k8sSub.addItem(mItem)
        }
        if k8sRunning {
            addAction("Disable Kubernetes", to: k8sSub) { [weak self] in
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = try? FirnHostClient.requestJSON(method: "POST", path: "/k8s/disable", timeoutSeconds: 30)
                    self?.refreshStatus()
                }
            }
            if k8sFrozen {
                addAction("Thaw Kubernetes Cgroup", to: k8sSub) { [weak self] in
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = try? FirnHostClient.requestJSON(method: "POST", path: "/k8s/thaw", timeoutSeconds: 15)
                        self?.refreshStatus()
                    }
                }
            } else {
                addAction("Freeze Kubernetes Cgroup", to: k8sSub) { [weak self] in
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = try? FirnHostClient.requestJSON(method: "POST", path: "/k8s/freeze", timeoutSeconds: 15)
                        self?.refreshStatus()
                    }
                }
            }
            addAction("Merge Kubeconfig (~/.kube/config)", to: k8sSub) { [weak self] in
                self?.runCLIAction(["k8s", "kubeconfig", "--write"])
            }
            addAction("Copy kubectl --context firn", to: k8sSub) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("kubectl --context firn get pods -A", forType: .string)
            }
        } else {
            addAction("Enable Kubernetes (k3s)", to: k8sSub) { [weak self] in
                self?.runCLIAction(["k8s", "enable"])
            }
        }
        k8sItem.submenu = k8sSub
        menu.addItem(k8sItem)

        // Multi-Distro Linux Machines submenu
        let machineList = (machinesPayload?["machines"] as? [[String: Any]]) ?? []
        let machinesMenuItem = NSMenuItem(title: "Linux Machines (\(machineList.count))", action: nil, keyEquivalent: "")
        let machinesSub = NSMenu()
        if machineList.isEmpty {
            let emptyM = NSMenuItem(title: "None (`firn machine create <name>`)", action: nil, keyEquivalent: "")
            emptyM.isEnabled = false
            machinesSub.addItem(emptyM)
        } else {
            for m in machineList {
                let mName = (m["name"] as? String) ?? "unknown"
                let mDistro = (m["distro"] as? String) ?? ""
                let mState = (m["state"] as? String) ?? ""
                let mMem = (m["memoryBytes"] as? NSNumber)?.uint64Value ?? 0
                let containerName = (m["container"] as? String) ?? "firn-machine-\(mName)"
                let rowItem = NSMenuItem(title: "\(mName) [\(mDistro) • \(mState)] \(FirnHostClient.formatBytes(mMem))", action: nil, keyEquivalent: "")
                let rowSub = NSMenu()
                let encodedM = mName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? mName
                if mState == "running" {
                    addAction("Open Shell in Terminal", to: rowSub) { [weak self] in
                        self?.openShellInTerminal(args: ["machine", "shell", mName])
                    }
                    addAction("View Logs…", to: rowSub) { [weak self] in
                        self?.openLogsWindow(
                            title: "Machine Logs: \(mName)",
                            dockerArgs: ["--context", FirnConfig.defaultDockerContext, "logs", "-f", "--tail", "200", containerName]
                        )
                    }
                    addAction("Stop Machine", to: rowSub) { [weak self] in
                        DispatchQueue.global(qos: .userInitiated).async {
                            _ = try? FirnHostClient.requestJSON(method: "POST", path: "/machines/\(encodedM)/stop", timeoutSeconds: 30)
                            self?.refreshStatus()
                        }
                    }
                } else {
                    addAction("Start Machine", to: rowSub) { [weak self] in
                        DispatchQueue.global(qos: .userInitiated).async {
                            _ = try? FirnHostClient.requestJSON(method: "POST", path: "/machines/\(encodedM)/start", timeoutSeconds: 30)
                            self?.refreshStatus()
                        }
                    }
                }
                rowItem.submenu = rowSub
                machinesSub.addItem(rowItem)
            }
        }
        machinesMenuItem.submenu = machinesSub
        menu.addItem(machinesMenuItem)

        menu.addItem(.separator())

        // Compose stacks
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

                addAction("View Compose Logs…", to: sub) { [weak self] in
                    self?.openLogsWindow(
                        title: "Stack Logs: \(name)",
                        dockerArgs: ["--context", FirnConfig.defaultDockerContext, "compose", "-p", name, "logs", "-f", "--tail", "200"]
                    )
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
        addAction("Hibernate VM (0 MiB Host RAM)", to: menu) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = try? FirnHostClient.requestJSON(method: "POST", path: "/hibernate", timeoutSeconds: 120)
                self?.refreshStatus()
            }
        }
        addAction("Open Linux Shell", to: menu) { [weak self] in
            self?.openShellInTerminal(args: ["shell"])
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
        appendVersionAndUpdateItems(to: menu)
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
