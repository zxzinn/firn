import AppKit
import FirnCore
import SwiftUI

enum FirnControlSheet: Identifiable {
    case snapshot(initialVolume: String)
    case cloneVolume(name: String, isSnapshot: Bool)
    case createMachine
    case cloneMachine(source: String)
    case pruneOrphans

    var id: String {
        switch self {
        case let .snapshot(vol): return "snapshot:\(vol)"
        case let .cloneVolume(name, isSnap): return "cloneVol:\(isSnap):\(name)"
        case .createMachine: return "createMachine"
        case let .cloneMachine(src): return "cloneMachine:\(src)"
        case .pruneOrphans: return "pruneOrphans"
        }
    }
}

enum FirnControlAlert: Identifiable {
    case removeOrphan(FirnStackInfo)
    case deleteSnapshot(String)
    case deleteMachine(String)
    case deepPrune
    case clearCache
    case resetK8s

    var id: String {
        switch self {
        case let .removeOrphan(stack): return "removeOrphan:\(stack.project)"
        case let .deleteSnapshot(name): return "deleteSnap:\(name)"
        case let .deleteMachine(name): return "deleteMachine:\(name)"
        case .deepPrune: return "deepPrune"
        case .clearCache: return "clearCache"
        case .resetK8s: return "resetK8s"
        }
    }

    var title: String {
        switch self {
        case .removeOrphan: return "Remove Orphaned Stack?"
        case .deleteSnapshot: return "Delete Snapshot?"
        case .deleteMachine: return "Delete Linux Machine?"
        case .deepPrune: return "Deep Prune Docker Storage?"
        case .clearCache: return "Clear Registry Cache?"
        case .resetK8s: return "Reset Kubernetes Cluster?"
        }
    }

    var message: String {
        switch self {
        case let .removeOrphan(stack):
            return "Missing directory: \(stack.workingDir)\nRemoves containers and networks while preserving named volumes."
        case let .deleteSnapshot(name):
            return "Delete snapshot '\(name)' from /var/lib/firn/snapshots?"
        case let .deleteMachine(name):
            return "Delete machine '\(name)' container and home volume?"
        case .deepPrune:
            return "Remove all unused images, stopped containers, and build cache, then run online fstrim."
        case .clearCache:
            return "Delete all cached OCI blobs and manifests under /var/lib/firn/registry-cache."
        case .resetK8s:
            return "Delete k3s state and pods inside /var/lib/firn/k3s (k3s binary stays installed)."
        }
    }

    var confirmButtonTitle: String {
        switch self {
        case .removeOrphan: return "Remove Containers & Networks"
        case .deleteSnapshot: return "Delete"
        case .deleteMachine: return "Delete"
        case .deepPrune: return "Prune All & Trim"
        case .clearCache: return "Clear All Cached Blobs"
        case .resetK8s: return "Reset k3s"
        }
    }

    @MainActor
    func execute(on store: FirnStore) {
        switch self {
        case let .removeOrphan(stack):
            let enc = stack.project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stack.project
            store.performDaemonPost(label: "Removing '\(stack.project)'…", path: "/projects/\(enc)/remove", timeoutSeconds: 60) { _ in
                "Removed '\(stack.project)'"
            }
        case let .deleteSnapshot(name):
            let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            store.performDaemonPost(label: "Deleting snapshot '\(name)'…", path: "/volumes/snapshots/\(enc)/delete", timeoutSeconds: 30) { _ in
                "Deleted snapshot '\(name)'"
            }
        case let .deleteMachine(name):
            let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            store.performDaemonPost(label: "Deleting '\(name)'…", path: "/machines/\(enc)/delete", timeoutSeconds: 30) { _ in
                "Deleted machine '\(name)'"
            }
        case .deepPrune:
            store.performDaemonPost(label: "Deep pruning Docker storage…", path: "/disk/prune?all=1", timeoutSeconds: 120) { _ in
                "Docker storage pruned & trimmed"
            }
        case .clearCache:
            store.performDaemonPost(label: "Clearing registry cache…", path: "/cache/prune?all=1", timeoutSeconds: 60) { _ in
                "Registry cache cleared"
            }
        case .resetK8s:
            store.performDaemonPost(label: "Resetting k3s cluster…", path: "/k8s/reset", timeoutSeconds: 30) { _ in
                "Kubernetes cluster reset"
            }
        }
    }
}

struct FirnControlSheetContent: View {
    let sheet: FirnControlSheet
    @ObservedObject var store: FirnStore

    var body: some View {
        switch sheet {
        case let .snapshot(initialVolume):
            CreateSnapshotSheet(volumes: store.dockerVolumes.map(\.name), initialVolume: initialVolume) { vol, snapName, quiesce in
                var body: [String: Any] = ["volume": vol, "quiesce": quiesce]
                if !snapName.isEmpty { body["snapshot"] = snapName }
                store.performDaemonPost(label: "Creating snapshot…", path: "/volumes/snapshot", body: body, timeoutSeconds: 180) { res in
                    "Created snapshot '\((res["name"] as? String) ?? vol)'"
                }
            }
        case let .cloneVolume(srcName, isSnap):
            CloneVolumeSheet(sourceName: srcName, isSnapshot: isSnap) { target, overwrite in
                let body: [String: Any] = [
                    "source": srcName,
                    "target": target,
                    "fromSnapshot": isSnap,
                    "quiesce": !isSnap,
                    "overwrite": overwrite,
                ]
                store.performDaemonPost(label: "Cloning to '\(target)'…", path: "/volumes/clone", body: body, timeoutSeconds: 180) { _ in
                    "Cloned '\(srcName)' → '\(target)'"
                }
            }
        case .createMachine:
            CreateMachineSheet { name, distro in
                let body: [String: Any] = [
                    "name": name,
                    "distro": distro,
                    "hostHome": FileManager.default.homeDirectoryForCurrentUser.path,
                ]
                store.performDaemonPost(label: "Creating \(distro) machine '\(name)'…", path: "/machines/create", body: body, timeoutSeconds: 180) { _ in
                    "Machine '\(name)' created"
                }
            }
        case let .cloneMachine(src):
            CloneMachineSheet(sourceName: src) { dst in
                let enc = src.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? src
                store.performDaemonPost(label: "Cloning machine '\(src)'…", path: "/machines/\(enc)/clone", body: ["target": dst], timeoutSeconds: 180) { _ in
                    "Cloned '\(src)' → '\(dst)'"
                }
            }
        case .pruneOrphans:
            OrphanedPruneSheet(orphanedStacks: store.stacks.filter(\.orphaned)) { removeVolumes in
                let suffix = removeVolumes ? "?volumes=1" : ""
                store.performDaemonPost(label: "Pruning orphaned stacks…", path: "/stacks/prune\(suffix)", timeoutSeconds: 120) { res in
                    let count = (res["removedCount"] as? NSNumber)?.intValue ?? 0
                    return "Pruned \(count) orphaned stack(s)"
                }
            }
        }
    }
}

struct LogsSheetView: View {
    @ObservedObject var session: FirnLogSession
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.headline)
                    Text(session.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search logs…", text: $session.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(width: 210)
                .firnGlassCapsule()

                Button(session.isPaused ? "Resume" : "Pause") {
                    session.isPaused.toggle()
                }
                .firnGlassButton()
                .controlSize(.small)

                Button("Copy") { session.copyAll() }
                    .firnGlassButton()
                    .controlSize(.small)

                Button("Clear") { session.clear() }
                    .firnGlassButton()
                    .controlSize(.small)

                Button("Done") { onClose() }
                    .firnGlassButton(prominent: true)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.filteredText.isEmpty ? "Waiting for log output…" : session.filteredText)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    Color.clear.frame(height: 1).id("log-bottom")
                }
                .background(Color.black.opacity(0.18))
                .onChange(of: session.lines.count) { _, _ in
                    if !session.isPaused {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(width: 820, height: 520)
    }
}

struct CreateSnapshotSheet: View {
    @Environment(\.dismiss) private var dismiss
    let volumes: [String]
    @FirnState private var volume: String
    @FirnState private var snapshotName = ""
    @FirnState private var quiesce = true
    let onCreate: (String, String, Bool) -> Void

    init(volumes: [String], initialVolume: String, onCreate: @escaping (String, String, Bool) -> Void) {
        self.volumes = volumes
        self._volume = FirnState(initialValue: initialVolume.isEmpty ? (volumes.first ?? "") : initialVolume)
        self.onCreate = onCreate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Volume Snapshot").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Source Docker Volume").font(.caption).foregroundStyle(.secondary)
                if volumes.isEmpty {
                    TextField("volume-name", text: $volume).textFieldStyle(.roundedBorder)
                } else {
                    Picker("Volume", selection: $volume) {
                        ForEach(volumes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Snapshot Name (optional, auto-timestamped if empty)").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. pre-migration", text: $snapshotName).textFieldStyle(.roundedBorder)
            }
            Toggle("Quiesce running containers (--quiesce)", isOn: $quiesce)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Snapshot") {
                    let v = volume.trimmingCharacters(in: .whitespacesAndNewlines)
                    let s = snapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !v.isEmpty else { return }
                    dismiss()
                    onCreate(v, s, quiesce)
                }
                .buttonStyle(.borderedProminent)
                .disabled(volume.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct CloneVolumeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sourceName: String
    let isSnapshot: Bool
    @FirnState private var targetName: String
    @FirnState private var overwrite = false
    let onClone: (String, Bool) -> Void

    init(sourceName: String, isSnapshot: Bool, onClone: @escaping (String, Bool) -> Void) {
        self.sourceName = sourceName
        self.isSnapshot = isSnapshot
        self._targetName = FirnState(initialValue: "\(sourceName)-clone")
        self.onClone = onClone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone \(isSnapshot ? "Snapshot" : "Volume") '\(sourceName)'").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Target Docker Volume Name").font(.caption).foregroundStyle(.secondary)
                TextField("target-volume", text: $targetName).textFieldStyle(.roundedBorder)
            }
            Toggle("Overwrite target if it already exists", isOn: $overwrite)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clone") {
                    let t = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    dismiss()
                    onClone(t, overwrite)
                }
                .buttonStyle(.borderedProminent)
                .disabled(targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

struct CreateMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FirnState private var name = ""
    @FirnState private var distro = "ubuntu"
    let onCreate: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Persistent Linux Machine").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Machine Name").font(.caption).foregroundStyle(.secondary)
                TextField("devbox", text: $name).textFieldStyle(.roundedBorder)
            }
            Picker("Distribution:", selection: $distro) {
                ForEach(["ubuntu", "debian", "alpine", "arch", "fedora"], id: \.self) {
                    Text($0).tag($0)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    dismiss()
                    onCreate(trimmed, distro)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct CloneMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sourceName: String
    @FirnState private var targetName: String
    let onClone: (String) -> Void

    init(sourceName: String, onClone: @escaping (String) -> Void) {
        self.sourceName = sourceName
        self._targetName = FirnState(initialValue: "\(sourceName)-copy")
        self.onClone = onClone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone Machine '\(sourceName)'").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Target Machine Name").font(.caption).foregroundStyle(.secondary)
                TextField("target-machine", text: $targetName).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clone") {
                    let t = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    dismiss()
                    onClone(t)
                }
                .buttonStyle(.borderedProminent)
                .disabled(targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct OrphanedPruneSheet: View {
    @Environment(\.dismiss) private var dismiss
    let orphanedStacks: [FirnStackInfo]
    @FirnState private var removeVolumes = false
    let onConfirm: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Prune \(orphanedStacks.count) Orphaned Compose Stack(s)").font(.headline)
            Text("The worktree directories for these stacks no longer exist on macOS:")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(orphanedStacks) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.project).font(.subheadline.weight(.semibold))
                            Text("Missing: \(s.workingDir)").font(.caption).foregroundStyle(Color.orange)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 200)

            Toggle("Also remove associated named volumes (--volumes)", isOn: $removeVolumes)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove Orphaned Stacks", role: .destructive) {
                    dismiss()
                    onConfirm(removeVolumes)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
