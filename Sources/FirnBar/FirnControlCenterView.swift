import FirnCore
import SwiftUI

struct FirnControlCenterView: View {
    @ObservedObject var store: FirnStore

    @Environment(\.colorScheme) private var colorScheme
    @FirnState private var activeSheet: FirnControlSheet?
    @FirnState private var activeAlert: FirnControlAlert?

    private var isAlertPresented: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { if !$0 { activeAlert = nil } }
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack(alignment: .bottom) {
                GlacierAmbientBackdrop()

                VStack(spacing: 0) {
                    topGlassHeader
                    Divider().opacity(0.08)
                    ScrollView {
                        detailBody
                            .padding(.horizontal, 24)
                            .padding(.vertical, 20)
                            .frame(maxWidth: 1180, alignment: .leading)
                    }
                }

                if let toast = store.toast {
                    toastBanner(toast)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: store.toast)
        }
        .tint(FirnTheme.cobalt(colorScheme))
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 960, minHeight: 620)
        .sheet(item: $store.activeLogSession, onDismiss: { store.closeLogsSheet() }) { session in
            LogsSheetView(session: session) {
                store.closeLogsSheet()
            }
        }
        .sheet(item: $activeSheet) { sheet in
            FirnControlSheetContent(sheet: sheet, store: store)
        }
        .sheet(isPresented: $store.showCommandPalette) {
            CommandPaletteView(store: store)
        }
        .alert(
            activeAlert?.title ?? "",
            isPresented: isAlertPresented,
            presenting: activeAlert
        ) { alert in
            Button(alert.confirmButtonTitle, role: .destructive) {
                alert.execute(on: store)
                activeAlert = nil
            }
            Button("Cancel", role: .cancel) {
                activeAlert = nil
            }
        } message: { alert in
            Text(alert.message)
        }
        .onChange(of: store.selectedSection) { _, next in
            if next == .volumes || next == .cache {
                store.refreshDockerInventory()
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FirnLogoBadge(size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Firn")
                            .font(.title3.weight(.semibold))
                        Text("v\(store.cliVersion)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    vmStatePill
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            List(DashboardSection.allCases, selection: $store.selectedSection) { sec in
                HStack(spacing: 9) {
                    Image(systemName: sec.icon)
                        .frame(width: 18)
                        .foregroundStyle(store.selectedSection == sec ? Color.primary : Color.secondary)
                    Text(sec.rawValue)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    sidebarBadge(for: sec)
                }
                .padding(.vertical, 3)
                .tag(sec)
            }
            .listStyle(.sidebar)

            VStack(spacing: 8) {
                if let tag = store.availableUpdateTag {
                    Button {
                        store.openTerminalShell(cliArgs: ["upgrade"])
                    } label: {
                        Label("Update to \(tag)", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .firnGlassButton(prominent: true)
                    .controlSize(.small)
                }

                HStack(spacing: 6) {
                    switch store.vmState {
                    case .running:
                        Button {
                            store.openTerminalShell(cliArgs: ["shell"])
                        } label: {
                            Label("Shell", systemImage: "terminal")
                                .frame(maxWidth: .infinity)
                        }
                        .firnGlassButton()
                        .controlSize(.small)

                        Button {
                            store.performDaemonPost(label: "Hibernating VM…", path: "/hibernate", timeoutSeconds: 120) { _ in
                                "VM hibernated (0 MiB XPC)"
                            }
                        } label: {
                            Label("Hibernate", systemImage: "moon.zzz")
                                .frame(maxWidth: .infinity)
                        }
                        .firnGlassButton()
                        .controlSize(.small)

                    case .hibernated:
                        Button {
                            store.performDaemonPost(label: "Resuming VM…", path: "/resume", timeoutSeconds: 120) { _ in
                                "VM resumed"
                            }
                        } label: {
                            Label("Resume VM", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .firnGlassButton(prominent: true)
                        .controlSize(.small)

                    case .offline:
                        Button {
                            store.performCLI(label: "Starting Firn VM…", args: ["up"], successMessage: "Firn VM started")
                        } label: {
                            Label("Start Firn VM", systemImage: "power")
                                .frame(maxWidth: .infinity)
                        }
                        .firnGlassButton(prominent: true)
                        .controlSize(.small)
                    }
                }
            }
            .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 222, ideal: 244, max: 274)
    }

    @ViewBuilder
    private func sidebarBadge(for sec: DashboardSection) -> some View {
        switch sec {
        case .stacks:
            if store.orphanedCount > 0 {
                PillBadge(text: "\(store.orphanedCount)!", color: FirnTheme.amber(colorScheme))
            } else if !store.stacks.isEmpty {
                Text("\(store.stacks.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .volumes:
            if !store.snapshots.isEmpty {
                Text("\(store.snapshots.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .cache:
            if store.cache.hits > 0 {
                Text("\(store.cache.hits)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .kubernetes:
            if store.k8s.running {
                let k8sColor = store.k8s.frozen
                    ? FirnTheme.frozen(colorScheme)
                    : (store.k8s.ready ? FirnTheme.healthy(colorScheme) : FirnTheme.amber(colorScheme))
                Circle()
                    .fill(k8sColor)
                    .frame(width: 7, height: 7)
            }
        case .machines:
            if !store.machines.isEmpty {
                Text("\(store.machines.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    private var vmStatePill: some View {
        let color: Color = switch store.vmState {
        case .running: FirnTheme.healthy(colorScheme)
        case .hibernated: FirnTheme.frozen(colorScheme)
        case .offline: .secondary
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(store.vmState == .running ? "\(store.vmState.rawValue) • \(store.backend)" : store.vmState.rawValue)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var topGlassHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedSection.rawValue)
                    .font(.title2.weight(.semibold))
                Text(sectionSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if let busy = store.busyAction {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .firnGlassCapsule()
            }

            FirnGlassGroup(spacing: 8) {
                Button {
                    store.showCommandPalette = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                        Text("⌘K")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Command Palette (⌘K)")
                .firnGlassButton()

                headerSectionActions
                Button {
                    store.onRequestRefresh?()
                    store.refreshDockerInventory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Status")
                .firnGlassButton()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var sectionSubtitle: String {
        switch store.selectedSection {
        case .overview:
            if store.vmState == .running {
                return "\(store.stacks.count) stacks • \(store.runningContainersTotal) running containers • APFS \(FirnHostClient.formatBytes(store.disk.hostAllocatedBytes)) / \(FirnHostClient.formatBytes(store.disk.hostLogicalBytes))"
            }
            return store.vmState == .hibernated ? "Suspended to APFS snapshot (0 MiB VM XPC)" : "Daemon not running — start VM to manage containers"
        case .stacks:
            return "\(store.stacks.count) stack(s) • \(store.runningContainersTotal) running, \(store.pausedContainersTotal) frozen, \(store.orphanedCount) orphaned"
        case .volumes:
            return "\(store.snapshots.count) snapshot(s) (\(FirnHostClient.formatBytes(store.disk.snapshotsBytes))) • \(store.dockerVolumes.count) Docker volume(s)"
        case .cache:
            return "\(store.cache.mirrorURL) • \(store.cache.hits) hits (\(FirnHostClient.formatBytes(store.cache.savedBytes)) saved) • \(store.dockerImages.count) local images"
        case .kubernetes:
            return store.k8s.running ? "\(store.k8s.version) • \(store.k8sServices.count) *.k8s.\(store.network.domain) endpoints" : "Embedded single-node k3s cluster"
        case .machines:
            return "\(store.machines.count) persistent Linux machine(s) sharing $HOME"
        case .network:
            return "*.\(store.network.domain) • HTTP :\(store.network.httpProxyPort) • HTTPS :\(store.network.httpsProxyPort)"
        }
    }

    @ViewBuilder
    private var headerSectionActions: some View {
        switch store.selectedSection {
        case .overview:
            if store.vmState == .running {
                Button("Shrink Balloon") {
                    store.performDaemonPost(label: "Shrinking balloon…", path: "/balloon/shrink") { _ in
                        "Balloon shrunk to guest demand"
                    }
                }
                .firnGlassButton()
            }
        case .stacks:
            if store.orphanedCount > 0 {
                Button("Prune \(store.orphanedCount) Orphan(s)…") {
                    activeSheet = .pruneOrphans
                }
                .firnGlassButton(prominent: true)
            }
        case .volumes:
            if store.vmState == .running {
                Button("New Snapshot…") {
                    activeSheet = .snapshot(initialVolume: store.dockerVolumes.first?.name ?? "")
                }
                .firnGlassButton(prominent: true)
            }
        case .cache:
            if store.vmState == .running {
                Button("Refresh Usage") {
                    store.triggerFullDiskRefresh()
                }
                .firnGlassButton()
            }
        case .kubernetes:
            if store.vmState == .running {
                if store.k8s.running {
                    Button("Merge Kubeconfig") {
                        store.performCLI(label: "Merging ~/.kube/config…", args: ["k8s", "kubeconfig", "--write"], successMessage: "Merged ~/.kube/config")
                    }
                    .firnGlassButton()
                } else {
                    Button("Enable k3s") {
                        store.performCLI(label: "Bootstrapping k3s…", args: ["k8s", "enable"], successMessage: "Kubernetes (k3s) enabled")
                    }
                    .firnGlassButton(prominent: true)
                }
            }
        case .machines:
            if store.vmState == .running {
                Button("New Machine…") {
                    activeSheet = .createMachine
                }
                .firnGlassButton(prominent: true)
            }
        case .network:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detailBody: some View {
        if store.vmState == .offline && store.selectedSection != .network {
            OfflineHeroCard(store: store)
        } else {
            switch store.selectedSection {
            case .overview:
                OverviewSectionView(store: store)
            case .stacks:
                StacksSectionView(store: store) { stack in
                    activeAlert = .removeOrphan(stack)
                }
            case .volumes:
                VolumesSectionView(
                    store: store,
                    onSnapshotVolume: { vol in activeSheet = .snapshot(initialVolume: vol) },
                    onClone: { name, isSnap in activeSheet = .cloneVolume(name: name, isSnapshot: isSnap) },
                    onDeleteSnapshot: { name in activeAlert = .deleteSnapshot(name) }
                )
            case .cache:
                CacheAndImagesSectionView(
                    store: store,
                    onDeepPrune: { activeAlert = .deepPrune },
                    onClearCache: { activeAlert = .clearCache }
                )
            case .kubernetes:
                KubernetesSectionView(store: store) {
                    activeAlert = .resetK8s
                }
            case .machines:
                MachinesSectionView(
                    store: store,
                    onCreate: { activeSheet = .createMachine },
                    onClone: { src in activeSheet = .cloneMachine(source: src) },
                    onDelete: { name in activeAlert = .deleteMachine(name) }
                )
            case .network:
                NetworkAndSettingsSectionView(store: store)
            }
        }
    }

    private func toastBanner(_ toast: FirnToast) -> some View {
        HStack(spacing: 8) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? FirnTheme.amber(colorScheme) : FirnTheme.healthy(colorScheme))
            Text(toast.message)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .firnGlassCapsule(tint: toast.isError ? FirnTheme.amber(colorScheme).opacity(0.16) : nil)
        .shadow(color: Color.black.opacity(0.16), radius: 10, x: 0, y: 4)
    }
}
