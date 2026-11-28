import FirnCore
import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var store: FirnStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FirnState private var query = ""
    @FocusState private var searchFocused: Bool

    private struct PaletteItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let category: String
        let icon: String
        let action: () -> Void
    }

    private var allItems: [PaletteItem] {
        var items: [PaletteItem] = []

        for (index, sec) in DashboardSection.allCases.enumerated() {
            items.append(PaletteItem(
                id: "sec:\(sec.rawValue)",
                title: "Go to \(sec.rawValue)",
                subtitle: "Shortcut ⌘\(index + 1)",
                category: "Navigate",
                icon: sec.icon
            ) {
                store.selectedSection = sec
            })
        }

        switch store.vmState {
        case .running:
            items.append(PaletteItem(id: "act:shrink", title: "Shrink Memory Balloon", subtitle: "Release unused guest RAM back to macOS", category: "VM", icon: "arrow.down.right.and.arrow.up.left") {
                store.performDaemonPost(label: "Shrinking balloon…", path: "/balloon/shrink") { _ in "Balloon shrunk to guest demand" }
            })
            items.append(PaletteItem(id: "act:reclaim", title: "Reclaim Memory Pressure", subtitle: "Freeze idle/orphaned stacks & shrink balloon", category: "VM", icon: "sparkles") {
                store.performDaemonPost(label: "Running memory reclaim…", path: "/memory-pressure/reclaim?level=warning&force=1") { res in
                    let frozen = (res["frozenProjects"] as? [String]) ?? []
                    return frozen.isEmpty ? "Balloon converged" : "Froze & reclaimed: \(frozen.joined(separator: ", "))"
                }
            })
            items.append(PaletteItem(id: "act:trim", title: "fstrim Sparse Disk", subtitle: "Reclaim freed blocks in APFS data.ext4", category: "VM", icon: "scissors") {
                store.performDaemonPost(label: "Trimming sparse disk…", path: "/disk/trim", timeoutSeconds: 60) { _ in "APFS sparse disk trimmed" }
            })
            items.append(PaletteItem(id: "act:shell", title: "Open Linux Shell", subtitle: "Interactive PTY via vsock", category: "VM", icon: "terminal") {
                store.openTerminalShell(cliArgs: ["shell"])
            })
            items.append(PaletteItem(id: "act:hibernate", title: "Hibernate VM", subtitle: "Save APFS state (0 MiB XPC footprint)", category: "VM", icon: "moon.zzz") {
                store.performDaemonPost(label: "Hibernating VM…", path: "/hibernate", timeoutSeconds: 120) { _ in "VM hibernated" }
            })
        case .hibernated:
            items.append(PaletteItem(id: "act:resume", title: "Resume Firn VM", subtitle: "Restore from APFS snapshot", category: "VM", icon: "play.fill") {
                store.performDaemonPost(label: "Resuming VM…", path: "/resume", timeoutSeconds: 120) { _ in "VM resumed" }
            })
        case .offline:
            items.append(PaletteItem(id: "act:up", title: "Start Firn VM", subtitle: "Boot lightweight Apple Virtualization VM", category: "VM", icon: "power") {
                store.performCLI(label: "Starting Firn VM…", args: ["up"], successMessage: "Firn VM started")
            })
        }

        items.append(PaletteItem(id: "act:refresh", title: "Refresh Status & Docker Inventory", subtitle: "Shortcut ⌘R", category: "VM", icon: "arrow.clockwise") {
            store.onRequestRefresh?()
            store.refreshDockerInventory()
        })

        for stack in store.stacks {
            let enc = stack.project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stack.project
            if stack.pausedCount > 0 {
                items.append(PaletteItem(
                    id: "thaw:\(stack.project)",
                    title: "Thaw Stack: \(stack.project)",
                    subtitle: "\(stack.containers.count) containers • \(FirnHostClient.formatBytes(stack.memoryBytes))",
                    category: "Stack",
                    icon: "play.circle"
                ) {
                    store.performDaemonPost(label: "Thawing '\(stack.project)'…", path: "/thaw/\(enc)") { _ in "Thawed '\(stack.project)'" }
                })
            } else if stack.runningCount > 0 {
                items.append(PaletteItem(
                    id: "freeze:\(stack.project)",
                    title: "Freeze Stack: \(stack.project)",
                    subtitle: "\(stack.containers.count) containers • \(FirnHostClient.formatBytes(stack.memoryBytes))",
                    category: "Stack",
                    icon: "pause.circle"
                ) {
                    store.performDaemonPost(label: "Freezing '\(stack.project)'…", path: "/freeze/\(enc)?reclaim=1") { _ in "Frozen '\(stack.project)'" }
                })
            }
            if stack.hasComposeProject {
                items.append(PaletteItem(
                    id: "slogs:\(stack.project)",
                    title: "Logs: \(stack.project)",
                    subtitle: "Stream Compose stack logs",
                    category: "Stack",
                    icon: "doc.text"
                ) {
                    store.openLogsSheet(
                        title: "Stack Logs: \(stack.project)",
                        subtitle: "\(stack.containers.count) containers",
                        dockerArgs: ["compose", "-p", stack.project, "logs", "-f", "--tail", "200"]
                    )
                })
            }

            for c in stack.containers where !c.name.isEmpty {
                items.append(PaletteItem(
                    id: "cshell:\(c.name)",
                    title: "Container Shell: \(c.name)",
                    subtitle: "\(stack.project) • \(c.state)\(c.ip.isEmpty ? "" : " • \(c.ip)")",
                    category: "Container",
                    icon: "terminal"
                ) {
                    store.openDockerExecInTerminal(containerName: c.name)
                })
                items.append(PaletteItem(
                    id: "clogs:\(c.name)",
                    title: "Container Logs: \(c.name)",
                    subtitle: stack.project,
                    category: "Container",
                    icon: "text.alignleft"
                ) {
                    store.openLogsSheet(
                        title: c.name,
                        subtitle: "Container logs (\(c.ip))",
                        dockerArgs: ["logs", "-f", "--tail", "250", c.name]
                    )
                })
            }
        }

        for m in store.machines where m.state == "running" {
            items.append(PaletteItem(
                id: "mshell:\(m.name)",
                title: "Machine Shell: \(m.name)",
                subtitle: "\(m.distro) • \(m.dnsName)",
                category: "Machine",
                icon: "desktopcomputer"
            ) {
                store.openTerminalShell(cliArgs: ["machine", "shell", m.name])
            })
        }

        return items
    }

    private var filteredItems: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allItems }
        return allItems.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.subtitle.localizedCaseInsensitiveContains(q)
                || $0.category.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Jump to section, stack, container, or action…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = filteredItems.first {
                            dismiss()
                            first.action()
                        }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button("Esc") {
                    dismiss()
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            if filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No matching commands")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredItems) { item in
                            Button {
                                dismiss()
                                item.action()
                            } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: item.icon)
                                        .frame(width: 18)
                                        .foregroundStyle(FirnTheme.cobalt(colorScheme))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text(item.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(item.category)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.12), in: Capsule())
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 560, height: 420)
        .onAppear {
            query = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                searchFocused = true
            }
        }
    }
}
