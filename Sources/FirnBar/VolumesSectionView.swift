import FirnCore
import SwiftUI

struct VolumesSectionView: View {
    @ObservedObject var store: FirnStore
    var onSnapshotVolume: (String) -> Void
    var onClone: (String, Bool) -> Void
    var onDeleteSnapshot: (String) -> Void

    @FirnState private var search = ""

    private var filteredVolumes: [FirnDockerVolumeInfo] {
        store.dockerVolumes.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Volume Snapshots (\(store.snapshots.count))", systemImage: "camera.aperture")
                        .font(.headline)
                    Spacer()
                    Text("Total \(FirnHostClient.formatBytes(store.disk.snapshotsBytes)) • CoW FICLONE / copy_file_range")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if store.snapshots.isEmpty {
                    Text("No snapshots yet. Click \"New Snapshot…\" or snapshot any Docker volume below for instant CoW forks.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    ForEach(store.snapshots) { snap in
                        SnapshotRowView(
                            snap: snap,
                            onClone: { onClone(snap.name, true) },
                            onDelete: { onDeleteSnapshot(snap.name) }
                        )
                        if snap.id != store.snapshots.last?.id {
                            Divider().opacity(0.12)
                        }
                    }
                }
            }
            .padding(16)
            .firnGlassCard(cornerRadius: 18)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Docker Volumes (\(store.dockerVolumes.count))", systemImage: "externaldrive.fill")
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Filter volumes…", text: $search)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(width: 240)
                    .firnGlassCapsule()
                }

                if filteredVolumes.isEmpty {
                    Text("No Docker volumes found.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(filteredVolumes) { vol in
                        DockerVolumeRowView(
                            vol: vol,
                            onSnapshot: { onSnapshotVolume(vol.name) },
                            onClone: { onClone(vol.name, false) }
                        )
                        if vol.id != filteredVolumes.last?.id {
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

private struct SnapshotRowView: View {
    let snap: FirnVolumeSnapshotInfo
    let onClone: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(snap.name)
                    .font(.subheadline.weight(.semibold))
                Text("Source: \(snap.volume) • \(snap.files) files • mode=\(snap.cloneMode) • \(snap.createdAt)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(FirnHostClient.formatBytes(snap.bytes))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Clone to Volume…", action: onClone)
                .firnGlassButton()
                .controlSize(.small)
            Button("Delete", role: .destructive, action: onDelete)
                .firnGlassButton()
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

private struct DockerVolumeRowView: View {
    let vol: FirnDockerVolumeInfo
    let onSnapshot: () -> Void
    let onClone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(vol.name)
                    .font(.subheadline.weight(.medium))
                Text(vol.mountpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Snapshot…", action: onSnapshot)
                .firnGlassButton()
                .controlSize(.small)
            Button("Clone…", action: onClone)
                .firnGlassButton()
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
