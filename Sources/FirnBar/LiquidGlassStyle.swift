import SwiftUI

// Avoids missing SwiftUIMacros plugin when compiling against SDK 27.2 with CommandLineTools.
typealias FirnState<Value> = SwiftUI.State<Value>

enum FirnTheme {
    static func cobalt(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.369, green: 0.580, blue: 1.000)
            : Color(red: 0.184, green: 0.435, blue: 0.929)
    }

    static func amber(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.878, green: 0.608, blue: 0.322)
            : Color(red: 0.784, green: 0.490, blue: 0.184)
    }

    static func healthy(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.290, green: 0.871, blue: 0.502)
            : Color(red: 0.086, green: 0.639, blue: 0.290)
    }

    static func frozen(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.580, green: 0.639, blue: 0.722)
            : Color(red: 0.392, green: 0.455, blue: 0.545)
    }
}

struct FirnGlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

private struct FirnGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    var interactive: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let strokeColor = colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.08)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let base = Glass.regular
            let tinted = tint != nil ? base.tint(tint) : base
            let glass = interactive ? tinted.interactive() : tinted
            content
                .glassEffect(glass, in: shape)
                .overlay(
                    shape.strokeBorder(strokeColor, lineWidth: 0.75)
                )
        } else {
            fallbackCard(content: content, shape: shape, strokeColor: strokeColor)
        }
        #else
        fallbackCard(content: content, shape: shape, strokeColor: strokeColor)
        #endif
    }

    private func fallbackCard(content: Content, shape: RoundedRectangle, strokeColor: Color) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.strokeBorder(strokeColor, lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.05), radius: 12, x: 0, y: 4)
    }
}

private struct FirnGlassCapsuleModifier: ViewModifier {
    var tint: Color?
    var interactive: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let strokeColor = colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let base = Glass.regular
            let tinted = tint != nil ? base.tint(tint) : base
            let glass = interactive ? tinted.interactive() : tinted
            content
                .glassEffect(glass, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(strokeColor, lineWidth: 0.65)
                )
        } else {
            fallbackCapsule(content: content, strokeColor: strokeColor)
        }
        #else
        fallbackCapsule(content: content, strokeColor: strokeColor)
        #endif
    }

    private func fallbackCapsule(content: Content, strokeColor: Color) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(strokeColor, lineWidth: 0.65)
            )
    }
}

extension View {
    func firnGlassCard(cornerRadius: CGFloat = 18, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(FirnGlassCardModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    func firnGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(FirnGlassCapsuleModifier(tint: tint, interactive: interactive))
    }

    @ViewBuilder
    func firnGlassButton(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            fallbackButton(prominent: prominent)
        }
        #else
        fallbackButton(prominent: prominent)
        #endif
    }

    @ViewBuilder
    private func fallbackButton(prominent: Bool) -> some View {
        if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

struct GlacierAmbientBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.067, green: 0.067, blue: 0.078),
                    Color(red: 0.082, green: 0.082, blue: 0.098),
                    Color(red: 0.102, green: 0.102, blue: 0.125),
                ]
                : [
                    Color(red: 0.973, green: 0.973, blue: 0.980),
                    Color(red: 0.949, green: 0.949, blue: 0.961),
                    Color(red: 0.925, green: 0.925, blue: 0.941),
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct LiveAreaSparkline: View {
    let values: [Double]
    var minUpperBound: Double = 10
    var accent: Color = Color(red: 0.184, green: 0.435, blue: 0.929)

    var body: some View {
        Canvas { ctx, size in
            guard size.width > 12, size.height > 12 else { return }

            for frac in [0.25, 0.5, 0.75] {
                let y = size.height * frac
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(grid, with: .color(.secondary.opacity(0.14)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 4]))
            }

            guard !values.isEmpty else { return }
            let upper = max(minUpperBound, (values.max() ?? 0) * 1.15)
            let padX: CGFloat = 4
            let usableW = max(1, size.width - padX * 2)
            let pts: [CGPoint]
            if values.count == 1 {
                let norm = min(1.0, max(0.0, values[0] / upper))
                let y = size.height - CGFloat(norm) * (size.height - 8) - 4
                pts = [CGPoint(x: padX, y: y), CGPoint(x: size.width - padX, y: y)]
            } else {
                let step = usableW / CGFloat(values.count - 1)
                pts = values.enumerated().map { idx, v in
                    let norm = min(1.0, max(0.0, v / upper))
                    return CGPoint(
                        x: padX + CGFloat(idx) * step,
                        y: size.height - CGFloat(norm) * (size.height - 10) - 5
                    )
                }
            }

            var fill = Path()
            fill.move(to: CGPoint(x: pts[0].x, y: size.height))
            for pt in pts { fill.addLine(to: pt) }
            fill.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
            fill.closeSubpath()

            ctx.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [accent.opacity(0.24), accent.opacity(0.01)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            var stroke = Path()
            stroke.move(to: pts[0])
            for pt in pts.dropFirst() { stroke.addLine(to: pt) }
            ctx.stroke(stroke, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            if let last = pts.last {
                let dotRect = CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)
                ctx.fill(Path(ellipseIn: dotRect), with: .color(accent))
                ctx.stroke(Path(ellipseIn: dotRect), with: .color(.white.opacity(0.92)), style: StrokeStyle(lineWidth: 1.2))
            }
        }
    }
}
