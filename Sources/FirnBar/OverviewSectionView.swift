import FirnCore
import SwiftUI

struct OfflineHeroCard: View {
    @ObservedObject var store: FirnStore

    var body: some View {
        VStack(spacing: 18) {
            FirnLogoBadge(size: 78)
            Text("Firn VM is Offline")
                .font(.title2.weight(.semibold))
            Text("Start the lightweight Apple Virtualization Linux runtime to manage Compose stacks, volumes, registry mirror, Kubernetes, and Linux machines.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            FirnGlassGroup(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        store.performCLI(label: "Starting Firn VM…", args: ["up"], successMessage: "Firn VM started")
                    } label: {
                        Label("Start Firn VM", systemImage: "power")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .firnGlassButton(prominent: true)

                    Button("Configure Runtime…") {
                        store.selectedSection = .network
                    }
                    .firnGlassButton()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .padding(.horizontal, 28)
        .firnGlassCard(cornerRadius: 24)
    }
}

struct HibernatedHeroCard: View {
    @ObservedObject var store: FirnStore

    var body: some View {
        VStack(spacing: 18) {
            FirnLogoBadge(size: 74)
            Text("VM Hibernated on APFS")
                .font(.title2.weight(.semibold))
            Text("Mode: \(store.hibernateMode) • Saved snapshot: \(FirnHostClient.formatBytes(store.disk.savedStateBytes)) • Host XPC footprint: 0 MiB (auto-wakes on Docker or HTTP/HTTPS requests)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button {
                store.performDaemonPost(label: "Resuming VM…", path: "/resume", timeoutSeconds: 120) { _ in
                    "VM resumed"
                }
            } label: {
                Label("Resume Firn VM", systemImage: "play.fill")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .firnGlassButton(prominent: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 28)
        .firnGlassCard(cornerRadius: 24)
    }
}

struct OverviewSectionView: View {
    @ObservedObject var store: FirnStore

    var body: some View {
        if store.vmState == .hibernated {
            HibernatedHeroCard(store: store)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                OverviewKPIGrid(store: store)
                OverviewTelemetryRow(store: store)
                OverviewControlsCard(store: store)
                OverviewStacksPreviewCard(store: store)
            }
        }
    }
}

private struct OverviewKPIGrid: View {
    @ObservedObject var store: FirnStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 185, maximum: 300), spacing: 14)], spacing: 14) {
            MetricGlassCard(
                title: "Host Footprint",
                value: FirnHostClient.formatBytes(store.hostFootprintBytes),
                detail: String(format: "VM %@ • CPU %.1f%%", FirnHostClient.formatBytes(store.vmFootprintBytes), store.cpuPercent),
                icon: "memorychip"
            )
            MetricGlassCard(
                title: "Guest RAM & Balloon",
                value: "\(FirnHostClient.formatBytes(store.vmMemUsed)) / \(FirnHostClient.formatBytes(store.vmMemTotal))",
                detail: "Balloon \(FirnHostClient.formatBytes(store.balloonTarget)) • Swap \(FirnHostClient.formatBytes(store.swapUsed))",
                icon: "cpu"
            )
            MetricGlassCard(
                title: "APFS Sparse Disk",
                value: FirnHostClient.formatBytes(store.disk.hostAllocatedBytes),
                detail: "of \(FirnHostClient.formatBytes(store.disk.hostLogicalBytes)) logical • \(FirnHostClient.formatBytes(store.disk.guestAvailableBytes)) guest free",
                icon: "internaldrive"
            )
            MetricGlassCard(
                title: "Memory Pressure",
                value: store.pressure.level.capitalized,
                detail: "Auto-reclaim \(store.pressure.enabled ? "on" : "off") • Reclaimed \(store.pressure.reclaimCount)x",
                icon: "waveform.path.ecg",
                tint: store.pressure.level == "normal" ? FirnTheme.healthy(colorScheme) : FirnTheme.amber(colorScheme)
            )
        }
    }
}

private struct OverviewTelemetryRow: View {
    @ObservedObject var store: FirnStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let footprintColor = FirnTheme.cobalt(colorScheme)
        let cpuColor = FirnTheme.amber(colorScheme)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Host Footprint History", systemImage: "chart.xyaxis.line")
                        .font(.headline)
                    Spacer()
                    Text(FirnHostClient.formatBytes(store.hostFootprintBytes))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(footprintColor)
                }
                LiveAreaSparkline(
                    values: store.samples.map(\.footprintMiB),
                    minUpperBound: 1024,
                    accent: footprintColor
                )
                .frame(height: 92)
            }
            .padding(16)
            .firnGlassCard(cornerRadius: 18)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Host VM CPU History", systemImage: "bolt.fill")
                        .font(.headline)
                    Spacer()
                    Text(String(format: "%.1f%%", store.cpuPercent))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(cpuColor)
                }
                LiveAreaSparkline(
                    values: store.samples.map(\.cpuPercent),
                    minUpperBound: 40,
                    accent: cpuColor
                )
                .frame(height: 92)
            }
            .padding(16)
            .firnGlassCard(cornerRadius: 18)
        }
    }
}

private struct OverviewControlsCard: View {
    @ObservedObject var store: FirnStore

    private var capabilityBadges: [String] {
        var out: [String] = []
        out.append(store.capabilities.firnfsActive ? "firnfs v3 inotify" : "virtiofs")
        out.append(store.capabilities.fastVirtioNet ? "jumbo-16k hostnet" : "VZ NAT")
        if store.cache.enabled && store.cache.listening {
            out.append("OCI Mirror :5000")
        }
        if store.capabilities.k3sRunning { out.append("k3s Ready") }
        if store.capabilities.utunConnected { out.append("utun Direct") }
        if store.capabilities.nestedKvm { out.append("Nested KVM") }
        if store.capabilities.gpuDri { out.append("GPU DRI") }
        if !store.capabilities.metalDeviceName.isEmpty {
            out.append(store.capabilities.metalDeviceName)
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Runtime Capabilities & Controls")
                    .font(.headline)
                Spacer()
                Text("\(store.network.portCount) forwarded ports • \(store.network.recordCount) DNS records")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            FlowBadgesView(badges: capabilityBadges)

            Divider().opacity(0.15)

            FirnGlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        store.performDaemonPost(label: "Running memory reclaim…", path: "/memory-pressure/reclaim?level=warning&force=1") { res in
                            let frozen = (res["frozenProjects"] as? [String]) ?? []
                            return frozen.isEmpty ? "Balloon converged" : "Froze & reclaimed: \(frozen.joined(separator: ", "))"
                        }
                    } label: {
                        Label("Reclaim Memory", systemImage: "sparkles")
                    }
                    .firnGlassButton()

                    Button {
                        store.performDaemonPost(label: "Trimming sparse disk…", path: "/disk/trim", timeoutSeconds: 60) { _ in
                            "APFS sparse disk trimmed"
                        }
                    } label: {
                        Label("fstrim Disk", systemImage: "scissors")
                    }
                    .firnGlassButton()

                    Button {
                        store.performDaemonPost(label: "Hibernating VM…", path: "/hibernate", timeoutSeconds: 120) { _ in
                            "VM hibernated"
                        }
                    } label: {
                        Label("Hibernate VM", systemImage: "moon.zzz")
                    }
                    .firnGlassButton()

                    Button {
                        store.openTerminalShell(cliArgs: ["shell"])
                    } label: {
                        Label("Open Linux Shell", systemImage: "terminal")
                    }
                    .firnGlassButton()

                    Spacer()

                    Button("Stop VM", role: .destructive) {
                        store.performDaemonPost(label: "Stopping Firn VM…", path: "/shutdown", timeoutSeconds: 10) { _ in
                            "Shutdown requested"
                        }
                    }
                    .foregroundStyle(Color.red)
                    .firnGlassButton()
                }
            }
        }
        .padding(16)
        .firnGlassCard(cornerRadius: 18)
    }
}

private struct OverviewStacksPreviewCard: View {
    @ObservedObject var store: FirnStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compose Stacks (\(store.stacks.count))")
                    .font(.headline)
                Spacer()
                Button("Manage All →") {
                    store.selectedSection = .stacks
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FirnTheme.cobalt(colorScheme))
            }

            if store.stacks.isEmpty {
                Text("No Compose stacks or standalone containers currently tracked.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                let preview = Array(store.stacks.prefix(6))
                ForEach(preview) { stack in
                    OverviewStackPreviewRow(store: store, stack: stack)
                    if stack.id != preview.last?.id {
                        Divider().opacity(0.12)
                    }
                }
            }
        }
        .padding(16)
        .firnGlassCard(cornerRadius: 18)
    }
}

private struct OverviewStackPreviewRow: View {
    @ObservedObject var store: FirnStore
    let stack: FirnStackInfo

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dotColor: Color = stack.orphaned
            ? FirnTheme.amber(colorScheme)
            : (stack.pausedCount > 0 ? FirnTheme.frozen(colorScheme) : FirnTheme.healthy(colorScheme))
        let enc = stack.project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stack.project
        return HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(stack.project)
                        .font(.subheadline.weight(.medium))
                    if stack.orphaned {
                        PillBadge(text: "ORPHANED", color: FirnTheme.amber(colorScheme))
                    }
                    if stack.exempt {
                        PillBadge(text: "Exempt", color: .secondary)
                    }
                }
                Text("\(stack.containers.count) \(stack.containers.count == 1 ? "container" : "containers") • idle \(String(format: "%.1fs", stack.idleForSeconds)) • \(stack.established) ext sockets")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(FirnHostClient.formatBytes(stack.memoryBytes))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            if stack.pausedCount > 0 {
                Button("Thaw") {
                    store.performDaemonPost(label: "Thawing '\(stack.project)'…", path: "/thaw/\(enc)") { _ in
                        "Thawed '\(stack.project)'"
                    }
                }
                .firnGlassButton()
                .controlSize(.small)
            } else if stack.runningCount > 0 {
                Button("Freeze") {
                    store.performDaemonPost(label: "Freezing '\(stack.project)'…", path: "/freeze/\(enc)?reclaim=1") { _ in
                        "Frozen '\(stack.project)'"
                    }
                }
                .firnGlassButton()
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
