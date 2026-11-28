import AppKit
import FirnCore
import SwiftUI

struct StacksSectionView: View {
    @ObservedObject var store: FirnStore
    var onRemoveOrphan: (FirnStackInfo) -> Void

    enum Filter: String, CaseIterable {
        case all = "All"
        case active = "Running"
        case frozen = "Frozen"
        case orphaned = "Orphaned"
    }

    @FirnState private var filter: Filter = .all
    @FirnState private var search = ""
    @FirnState private var expanded: Set<String> = []

    private var visibleStacks: [FirnStackInfo] {
        store.stacks.filter { s in
            let matchesFilter: Bool = switch filter {
            case .all: true
            case .active: s.runningCount > 0 && !s.orphaned
            case .frozen: s.pausedCount > 0
            case .orphaned: s.orphaned
            }
            guard matchesFilter else { return false }
            let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { return true }
            return s.project.localizedCaseInsensitiveContains(q)
                || s.workingDir.localizedCaseInsensitiveContains(q)
                || s.containers.contains { $0.name.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter stacks, worktree paths, or containers…", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .firnGlassCapsule()

                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }

            if visibleStacks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No matching Compose stacks")
                        .font(.headline)
                    Text("Start a Docker Compose stack with `--context firn` or clear your current filter.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
                .firnGlassCard()
            } else {
                ForEach(visibleStacks) { stack in
                    StackCardView(
                        store: store,
                        stack: stack,
                        isExpanded: expanded.contains(stack.project),
                        onToggleExpand: {
                            if expanded.contains(stack.project) {
                                expanded.remove(stack.project)
                            } else {
                                expanded.insert(stack.project)
                            }
                        },
                        onRemoveOrphan: { onRemoveOrphan(stack) }
                    )
                }
            }
        }
    }
}

private struct StackCardView: View {
    @ObservedObject var store: FirnStore
    let stack: FirnStackInfo
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onRemoveOrphan: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var statusBadge: (String, Color) {
        if stack.orphaned { return ("Orphaned", FirnTheme.amber(colorScheme)) }
        if stack.pausedCount > 0 { return ("Frozen (\(stack.pausedCount))", FirnTheme.frozen(colorScheme)) }
        if stack.runningCount > 0 { return ("Running (\(stack.runningCount))", FirnTheme.healthy(colorScheme)) }
        return ("Stopped", .secondary)
    }

    var body: some View {
        let enc = stack.project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stack.project
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(stack.project).font(.headline)
                        PillBadge(text: statusBadge.0, color: statusBadge.1)
                        if stack.exempt {
                            PillBadge(text: "Exempt", color: .secondary)
                        }
                    }

                    if !stack.workingDir.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: stack.orphaned ? "folder.badge.questionmark" : "folder")
                                .foregroundStyle(stack.orphaned ? FirnTheme.amber(colorScheme) : Color.secondary)
                            Text(stack.workingDir)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(stack.orphaned ? FirnTheme.amber(colorScheme) : Color.secondary)
                        }
                        .font(.caption)
                    }

                    HStack(spacing: 14) {
                        Text("RAM \(FirnHostClient.formatBytes(stack.memoryBytes))")
                        Text("Swap \(FirnHostClient.formatBytes(stack.swapBytes))")
                        Text(String(format: "Idle %.1fs", stack.idleForSeconds))
                        if stack.established > 0 {
                            Text("\(stack.established) external sockets")
                                .foregroundStyle(FirnTheme.cobalt(colorScheme))
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                Spacer()

                let memHistory = store.stackMemoryHistory[stack.project] ?? [Double(stack.memoryBytes) / (1024.0 * 1024.0)]
                let sparkColor: Color = stack.orphaned
                    ? FirnTheme.amber(colorScheme)
                    : (stack.pausedCount > 0 ? FirnTheme.frozen(colorScheme) : FirnTheme.cobalt(colorScheme))
                LiveAreaSparkline(
                    values: memHistory,
                    minUpperBound: 64,
                    accent: sparkColor
                )
                .frame(width: 92, height: 26)

                FirnGlassGroup(spacing: 6) {
                    HStack(spacing: 6) {
                        if stack.orphaned {
                            Button("Remove Orphan…", role: .destructive, action: onRemoveOrphan)
                                .firnGlassButton()
                        }
                        if stack.pausedCount > 0 {
                            Button("Thaw") {
                                store.performDaemonPost(label: "Thawing '\(stack.project)'…", path: "/thaw/\(enc)") { _ in
                                    "Thawed '\(stack.project)'"
                                }
                            }
                            .firnGlassButton(prominent: true)
                        } else if stack.runningCount > 0 {
                            Button("Freeze") {
                                store.performDaemonPost(label: "Freezing '\(stack.project)'…", path: "/freeze/\(enc)?reclaim=1") { _ in
                                    "Frozen '\(stack.project)'"
                                }
                            }
                            .firnGlassButton()
                        }
                        if stack.hasComposeProject {
                            Button("Logs") {
                                store.openLogsSheet(
                                    title: "Stack Logs: \(stack.project)",
                                    subtitle: "\(stack.containers.count) containers",
                                    dockerArgs: ["compose", "-p", stack.project, "logs", "-f", "--tail", "200"]
                                )
                            }
                            .firnGlassButton()

                            Menu {
                                Button("Restart Stack") {
                                    store.performDocker(label: "Restarting '\(stack.project)'…", args: ["compose", "-p", stack.project, "restart"], successMessage: "Restarted '\(stack.project)'")
                                }
                                Button("Stop Stack") {
                                    store.performDocker(label: "Stopping '\(stack.project)'…", args: ["compose", "-p", stack.project, "stop"], successMessage: "Stopped '\(stack.project)'")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .firnGlassButton()
                        }
                    }
                    .controlSize(.small)
                }
            }

            if !stack.endpoints.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(stack.endpoints) { ep in
                            if let url = ep.httpsURL ?? ep.httpURL {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Label("\(ep.label) ↗", systemImage: "globe")
                                        .font(.caption.weight(.medium))
                                }
                                .firnGlassButton()
                                .controlSize(.mini)
                            }
                        }
                    }
                }
            }

            if !stack.containers.isEmpty {
                Button(action: onToggleExpand) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                        Text("Containers (\(stack.containers.count))")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(spacing: 6) {
                        ForEach(stack.containers) { c in
                            StackContainerRow(store: store, container: c)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .firnGlassCard(cornerRadius: 18, tint: stack.orphaned ? FirnTheme.amber(colorScheme).opacity(0.06) : nil)
    }
}

private struct StackContainerRow: View {
    @ObservedObject var store: FirnStore
    let container: FirnContainerInfo

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dotColor: Color = container.paused
            ? FirnTheme.frozen(colorScheme)
            : (container.state == "running" ? FirnTheme.healthy(colorScheme) : .secondary)
        return HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(container.service.isEmpty ? container.name : container.service)
                .font(.callout.weight(.medium))
            Text(container.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if !container.ip.isEmpty {
                Text(container.ip)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(FirnHostClient.formatBytes(container.memoryBytes))
                .font(.caption.monospacedDigit())
                .frame(width: 72, alignment: .trailing)

            Button("Shell") {
                store.openDockerExecInTerminal(containerName: container.name)
            }
            .firnGlassButton()
            .controlSize(.mini)

            Button("Logs") {
                store.openLogsSheet(
                    title: container.name,
                    subtitle: "Container logs (\(container.ip))",
                    dockerArgs: ["logs", "-f", "--tail", "250", container.name]
                )
            }
            .firnGlassButton()
            .controlSize(.mini)
        }
        .padding(.vertical, 3)
    }
}
