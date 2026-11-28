import AppKit
import FirnCore
import SwiftUI

struct PillBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

struct MetricGlassCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(tint ?? Color.secondary)
            }
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .firnGlassCard(cornerRadius: 16)
    }
}

struct FlowBadgesView: View {
    let badges: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(badges.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .firnGlassCapsule()
                }
            }
        }
    }
}

struct IntegrationCard: View {
    let title: String
    let detail: String
    let installed: Bool
    let actionTitle: String
    var allowActionWhenInstalled: Bool = false
    let onAction: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: installed ? "checkmark.seal.fill" : "circle.dashed")
                    .font(.title3)
                    .foregroundStyle(installed ? FirnTheme.healthy(colorScheme) : Color.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 8)
                if !installed || allowActionWhenInstalled {
                    Button(actionTitle, action: onAction)
                        .firnGlassButton()
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .firnGlassCard(cornerRadius: 14)
    }
}
