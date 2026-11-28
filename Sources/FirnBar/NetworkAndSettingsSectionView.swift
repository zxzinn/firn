import FirnCore
import SwiftUI

struct NetworkAndSettingsSectionView: View {
    @ObservedObject var store: FirnStore

    @FirnState private var cpusText = ""
    @FirnState private var memText = ""
    @FirnState private var minBalloonText = ""
    @FirnState private var idleText = ""
    @FirnState private var hibText = ""
    @FirnState private var autoTrimText = ""
    @FirnState private var domainText = ""
    @FirnState private var exemptText = ""
    @FirnState private var diskSyncMode = "none"
    @FirnState private var fsMode = "firnfs"
    @FirnState private var nestedVirt = false
    @FirnState private var directRouteDNS = false
    @FirnState private var memoryPressureReclaim = true
    @FirnState private var loadedOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Label("macOS Integration & Local Domains (*.\(store.network.domain))", systemImage: "network.badge.shield.half.filled")
                    .font(.headline)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14)], spacing: 14) {
                    IntegrationCard(
                        title: "Split DNS (*.\(store.network.domain))",
                        detail: "/etc/resolver/\(store.network.domain) (:\(store.network.dnsPort))",
                        installed: store.network.hasResolver,
                        actionTitle: "Install DNS",
                        onAction: { store.openTerminalShell(cliArgs: ["dns", "install"]) }
                    )
                    IntegrationCard(
                        title: "Local Root CA Trust",
                        detail: store.network.caTrusted ? "Trusted in System Keychain (HTTPS :\(store.network.httpsProxyPort))" : "Untrusted — install for padlock HTTPS",
                        installed: store.network.caTrusted,
                        actionTitle: "Trust CA",
                        onAction: { store.openTerminalShell(cliArgs: ["ca", "install"]) }
                    )
                    IntegrationCard(
                        title: "Zero-Port :80 / :443 Redirect",
                        detail: "/etc/pf.anchors/dev.firn",
                        installed: store.network.pfRedirectActive,
                        actionTitle: "Install pf",
                        onAction: { store.openTerminalShell(cliArgs: ["https", "install"]) }
                    )
                    IntegrationCard(
                        title: "Host utun Container Routing",
                        detail: store.capabilities.utunConnected ? "Connected (10.87.0.0/24 & 10.88.0.0/16)" : "Direct 10.87.0.0/24 & 10.88.0.0/16",
                        installed: store.capabilities.utunConnected || store.network.routeDaemonInstalled,
                        actionTitle: "Install Route",
                        onAction: { store.openTerminalShell(cliArgs: ["route", "install"]) }
                    )
                    IntegrationCard(
                        title: "Default Docker Context",
                        detail: "Current: \(store.network.currentDockerContext.isEmpty ? "unknown" : store.network.currentDockerContext)",
                        installed: store.network.currentDockerContext == FirnConfig.defaultDockerContext,
                        actionTitle: store.network.currentDockerContext == FirnConfig.defaultDockerContext ? "Restore Previous" : "Use 'firn'",
                        allowActionWhenInstalled: true,
                        onAction: {
                            let useFirn = store.network.currentDockerContext != FirnConfig.defaultDockerContext
                            store.performCLI(label: "Switching Docker context…", args: ["context", useFirn ? "use" : "restore"], successMessage: "Updated Docker context")
                        }
                    )
                    IntegrationCard(
                        title: "Auto-Start LaunchAgent",
                        detail: FirnPaths.launchAgentURL.lastPathComponent,
                        installed: store.network.autostartInstalled,
                        actionTitle: store.network.autostartInstalled ? "Uninstall" : "Install",
                        allowActionWhenInstalled: true,
                        onAction: {
                            let install = !store.network.autostartInstalled
                            store.performCLI(label: install ? "Installing LaunchAgent…" : "Removing LaunchAgent…", args: ["autostart", install ? "install" : "uninstall"], successMessage: install ? "LaunchAgent installed" : "LaunchAgent removed")
                        }
                    )
                }
            }
            .padding(16)
            .firnGlassCard(cornerRadius: 18)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Runtime & VM Configuration", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Spacer()
                    Button("Save & Apply") {
                        saveForm()
                    }
                    .firnGlassButton(prominent: true)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 195), spacing: 14)], spacing: 12) {
                    configField("CPUs (restart VM)", text: $cpusText)
                    configField("Memory GiB (restart VM)", text: $memText)
                    configField("Min Balloon MiB (restart VM)", text: $minBalloonText)
                    configField("Idle Freeze Seconds (0 = off)", text: $idleText)
                    configField("Auto-Hibernate Seconds (0 = off)", text: $hibText)
                    configField("Auto fstrim Minutes (0 = off)", text: $autoTrimText)
                    configField("Local Domain", text: $domainText)
                    configField("Exempt Projects (comma)", text: $exemptText)
                }

                HStack(spacing: 20) {
                    Picker("Disk Sync (restart):", selection: $diskSyncMode) {
                        Text("none (fast)").tag("none")
                        Text("fsync (strict)").tag("fsync")
                    }
                    .frame(maxWidth: 260)

                    Picker("Host FS (restart):", selection: $fsMode) {
                        Text("firnfs (inotify + cache)").tag("firnfs")
                        Text("virtiofs (direct)").tag("virtiofs")
                    }
                    .frame(maxWidth: 280)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Auto-Reclaim on macOS Memory Pressure", isOn: $memoryPressureReclaim)
                    Toggle("Direct Container IP DNS via utun", isOn: $directRouteDNS)
                    Toggle("Nested Virtualization (/dev/kvm, restart VM)", isOn: $nestedVirt)
                }
            }
            .padding(16)
            .firnGlassCard(cornerRadius: 18)
        }
        .onAppear { syncFromStore() }
    }

    private func configField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func syncFromStore() {
        guard !loadedOnce else { return }
        let c = store.config
        cpusText = "\(c.cpus)"
        memText = "\(c.memoryGiB)"
        minBalloonText = "\(c.minBalloonMiB)"
        idleText = "\(c.idleSeconds)"
        hibText = "\(c.hibernateSeconds)"
        autoTrimText = "\(c.autoTrimMinutes)"
        domainText = c.domain
        exemptText = c.exemptProjects.joined(separator: ", ")
        diskSyncMode = c.diskSyncMode
        fsMode = c.fsMode
        nestedVirt = c.nestedVirtualization
        directRouteDNS = c.directRouteDNS
        memoryPressureReclaim = c.memoryPressureReclaim
        loadedOnce = true
    }

    private func saveForm() {
        var next = FirnConfig.load()
        if let v = Int(cpusText), v > 0 { next.cpus = v }
        if let v = Int(memText), v > 0 { next.memoryGiB = v }
        if let v = Int(minBalloonText), v >= 256 { next.minBalloonMiB = v }
        if let v = Int(idleText), v >= 0 { next.idleSeconds = v }
        if let v = Int(hibText), v >= 0 { next.hibernateSeconds = v }
        if let v = Int(autoTrimText), v >= 0 { next.autoTrimMinutes = v }
        let dom = domainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dom.isEmpty { next.domain = dom }
        next.exemptProjects = exemptText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        next.diskSyncMode = diskSyncMode
        next.fsMode = fsMode
        next.nestedVirtualization = nestedVirt
        next.directRouteDNS = directRouteDNS
        next.memoryPressureReclaim = memoryPressureReclaim
        store.saveRuntimeConfig(next)
    }
}
