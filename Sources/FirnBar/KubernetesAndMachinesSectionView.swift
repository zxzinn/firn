import AppKit
import FirnCore
import SwiftUI

struct KubernetesSectionView: View {
    @ObservedObject var store: FirnStore
    var onResetK8s: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let statusLabel = store.k8s.frozen ? "Frozen" : (store.k8s.ready ? "Ready" : (store.k8s.running ? "Starting" : "Stopped"))
        let statusColor: Color = store.k8s.frozen
            ? FirnTheme.frozen(colorScheme)
            : (store.k8s.ready ? FirnTheme.healthy(colorScheme) : .secondary)
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Label("Embedded Kubernetes (\(store.k8s.version))", systemImage: "circle.hexagongrid.fill")
                                .font(.headline)
                            PillBadge(text: statusLabel, color: statusColor)
                        }
                        Text("Memory: \(FirnHostClient.formatBytes(store.k8s.memoryBytes)) • Images synced with registry mirror \(store.cache.mirrorURL)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    FirnGlassGroup(spacing: 8) {
                        HStack(spacing: 8) {
                            if store.k8s.running {
                                if store.k8s.frozen {
                                    Button("Thaw Cluster") {
                                        store.performDaemonPost(label: "Thawing k3s…", path: "/k8s/thaw") { _ in "k3s thawed" }
                                    }
                                    .firnGlassButton(prominent: true)
                                } else {
                                    Button("Freeze Cluster") {
                                        store.performDaemonPost(label: "Freezing k3s…", path: "/k8s/freeze") { _ in "k3s frozen" }
                                    }
                                    .firnGlassButton()
                                }
                                Button("Disable") {
                                    store.performDaemonPost(label: "Stopping k3s…", path: "/k8s/disable") { _ in "k3s disabled" }
                                }
                                .firnGlassButton()
                                Button("Reset…", role: .destructive, action: onResetK8s)
                                    .firnGlassButton()
                            } else {
                                Button("Enable k3s") {
                                    store.performCLI(label: "Enabling Kubernetes (k3s)…", args: ["k8s", "enable"], successMessage: "Kubernetes enabled")
                                }
                                .firnGlassButton(prominent: true)
                            }
                        }
                        .controlSize(.small)
                    }
                }

                if store.k8s.running {
                    HStack(spacing: 10) {
                        Button("Copy kubectl --context firn") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("kubectl --context firn get pods -A", forType: .string)
                            store.showToast("Copied kubectl command")
                        }
                        .firnGlassButton()
                        .controlSize(.small)
                    }
                }
            }
            .padding(16)
            .firnGlassCard(cornerRadius: 18)

            VStack(alignment: .leading, spacing: 12) {
                Label("Auto-Discovered Services & Ingresses (*.k8s.\(store.network.domain))", systemImage: "network")
                    .font(.headline)

                if store.k8sServices.isEmpty {
                    Text(store.k8s.running ? "No non-system ClusterIP services or Ingresses discovered yet." : "Enable k3s above to inspect live Kubernetes routes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(store.k8sServices) { svc in
                        K8sServiceRowView(svc: svc, httpsPort: store.network.httpsProxyPort)
                        if svc.id != store.k8sServices.last?.id {
                            Divider().opacity(0.12)
                        }
                    }
                }
            }
            .padding(16)
            .firnGlassCard(cornerRadius: 18)
        }
    }
}

private struct K8sServiceRowView: View {
    let svc: FirnK8sServiceInfo
    let httpsPort: Int

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(svc.namespace)/\(svc.name)")
                    .font(.subheadline.weight(.semibold))
                Text("ClusterIP \(svc.clusterIP) • Ports: \(svc.ports)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let primary = svc.dnsNames.first,
               let url = URL(string: "https://\(primary):\(httpsPort)/") {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("https://\(primary):\(httpsPort) ↗", systemImage: "lock.fill")
                }
                .firnGlassButton()
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MachinesSectionView: View {
    @ObservedObject var store: FirnStore
    var onCreate: () -> Void
    var onClone: (String) -> Void
    var onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.machines.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Persistent Linux Machines")
                        .font(.headline)
                    Text("Launch Ubuntu, Debian, Alpine, Arch, or Fedora sandboxes that mount your macOS $HOME via firnfs and get automatic *.\(store.network.domain) DNS.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    Button("Create Linux Machine…", action: onCreate)
                        .firnGlassButton(prominent: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .firnGlassCard()
            } else {
                ForEach(store.machines) { machine in
                    MachineCardView(
                        store: store,
                        machine: machine,
                        onClone: { onClone(machine.name) },
                        onDelete: { onDelete(machine.name) }
                    )
                }
            }
        }
    }
}

private struct MachineCardView: View {
    @ObservedObject var store: FirnStore
    let machine: FirnMachineInfo
    let onClone: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let enc = machine.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? machine.name
        let stateColor: Color = machine.state == "running" ? FirnTheme.healthy(colorScheme) : .secondary
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(machine.name)
                        .font(.headline)
                    PillBadge(text: machine.distro.uppercased(), color: .secondary)
                    PillBadge(text: machine.state, color: stateColor)
                }
                Text("DNS: \(machine.dnsName) • IP: \(machine.ip.isEmpty ? "-" : machine.ip) • RAM: \(FirnHostClient.formatBytes(machine.memoryBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()

            FirnGlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    if machine.state == "running" {
                        Button("Shell") {
                            store.openTerminalShell(cliArgs: ["machine", "shell", machine.name])
                        }
                        .firnGlassButton(prominent: true)
                        Button("Logs") {
                            store.openLogsSheet(
                                title: "Machine Logs: \(machine.name)",
                                subtitle: "\(machine.distro) (\(machine.container))",
                                dockerArgs: ["logs", "-f", "--tail", "250", machine.container]
                            )
                        }
                        .firnGlassButton()
                        Button("Stop") {
                            store.performDaemonPost(label: "Stopping '\(machine.name)'…", path: "/machines/\(enc)/stop") { _ in "Stopped '\(machine.name)'" }
                        }
                        .firnGlassButton()
                    } else {
                        Button("Start") {
                            store.performDaemonPost(label: "Starting '\(machine.name)'…", path: "/machines/\(enc)/start") { _ in "Started '\(machine.name)'" }
                        }
                        .firnGlassButton(prominent: true)
                    }
                    Button("Clone…", action: onClone)
                        .firnGlassButton()
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .firnGlassButton()
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .firnGlassCard(cornerRadius: 18)
    }
}
