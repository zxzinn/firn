import FirnCore
import SwiftUI

struct CacheAndImagesSectionView: View {
    @ObservedObject var store: FirnStore
    var onDeepPrune: () -> Void
    var onClearCache: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FirnState private var search = ""

    private var filteredImages: [FirnDockerImageInfo] {
        store.dockerImages.filter {
            search.isEmpty || $0.displayRef.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            cacheOverviewCard
            imagesListCard
        }
    }

    private var cacheOverviewCard: some View {
        let statusText = store.cache.enabled && store.cache.listening ? "Active" : (store.cache.enabled ? "Configured" : "Disabled")
        let statusColor: Color = store.cache.listening ? FirnTheme.healthy(colorScheme) : .secondary
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Label("OCI Registry Pull-Through Cache", systemImage: "bolt.horizontal.circle.fill")
                            .font(.headline)
                        PillBadge(text: statusText, color: statusColor)
                    }
                    Text("Mirror \(store.cache.mirrorURL) → \(store.cache.upstream) (shared by dockerd & k3s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                FirnGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        Button(store.cache.enabled ? "Disable" : "Enable") {
                            store.performDaemonPost(
                                label: store.cache.enabled ? "Disabling cache…" : "Enabling cache…",
                                path: store.cache.enabled ? "/cache/disable" : "/cache/enable"
                            ) { _ in
                                store.cache.enabled ? "Registry cache disabled" : "Registry cache enabled"
                            }
                        }
                        .firnGlassButton()
                        Button("Prune Expired") {
                            store.performDaemonPost(label: "Pruning expired cache entries…", path: "/cache/prune") { _ in
                                "Cache pruned"
                            }
                        }
                        .firnGlassButton()
                        Button("Clear All…", role: .destructive, action: onClearCache)
                            .firnGlassButton()
                    }
                    .controlSize(.small)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                MetricGlassCard(
                    title: "Cache Usage",
                    value: FirnHostClient.formatBytes(store.cache.usedBytes),
                    detail: "of \(FirnHostClient.formatBytes(store.cache.maxBytes)) max",
                    icon: "internaldrive"
                )
                MetricGlassCard(
                    title: "Bandwidth Saved",
                    value: FirnHostClient.formatBytes(store.cache.savedBytes),
                    detail: "\(store.cache.hits) hits / \(store.cache.misses) misses",
                    icon: "arrow.down.circle",
                    tint: FirnTheme.healthy(colorScheme)
                )
                MetricGlassCard(
                    title: "Cached Artifacts",
                    value: "\(store.cache.blobCount) blobs",
                    detail: "\(store.cache.manifestCount) manifests",
                    icon: "shippingbox"
                )
                MetricGlassCard(
                    title: "Docker Reclaimable",
                    value: FirnHostClient.formatBytes(store.disk.dockerReclaimableBytes),
                    detail: store.disk.dockerDfPending ? "Scanning in background…" : "Images \(FirnHostClient.formatBytes(store.disk.dockerImagesBytes))",
                    icon: "sparkles"
                )
            }

            HStack(spacing: 10) {
                Button("Prune Build Cache & Dangling Images") {
                    store.performDaemonPost(label: "Pruning Docker cache…", path: "/disk/prune", timeoutSeconds: 120) { _ in
                        "Docker build cache pruned"
                    }
                }
                .firnGlassButton()
                Button("Deep Prune All Unused…", role: .destructive, action: onDeepPrune)
                    .firnGlassButton()
            }
            .controlSize(.small)
        }
        .padding(16)
        .firnGlassCard(cornerRadius: 18)
    }

    private var imagesListCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Local Docker Images (\(store.dockerImages.count))", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter images…", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(width: 240)
                .firnGlassCapsule()
            }

            if filteredImages.isEmpty {
                Text("No images matched.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredImages) { img in
                    DockerImageRowView(store: store, image: img)
                    if img.id != filteredImages.last?.id {
                        Divider().opacity(0.12)
                    }
                }
            }
        }
        .padding(16)
        .firnGlassCard(cornerRadius: 18)
    }
}

private struct DockerImageRowView: View {
    @ObservedObject var store: FirnStore
    let image: FirnDockerImageInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cube.box")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(image.displayRef)
                    .font(.subheadline.weight(.medium))
                Text("\(image.id) • \(image.created)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(image.size)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            if store.k8s.running {
                Button("Load to k3s") {
                    store.performCLI(label: "Loading \(image.displayRef) into k3s…", args: ["k8s", "load", image.displayRef], successMessage: "Loaded \(image.displayRef) into k8s.io")
                }
                .firnGlassButton()
                .controlSize(.small)
            }
            Button(role: .destructive) {
                store.performDocker(label: "Removing \(image.displayRef)…", args: ["rmi", image.displayRef], successMessage: "Removed \(image.displayRef)")
            } label: {
                Image(systemName: "trash")
            }
            .firnGlassButton()
            .controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}
