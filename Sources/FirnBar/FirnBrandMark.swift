import AppKit
import SwiftUI

enum FirnBrandMark {
    static func menuBarImage(hibernated: Bool = false, pressureWarning: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            let alpha: CGFloat = hibernated ? 0.55 : 1.0
            NSColor.labelColor.withAlphaComponent(alpha).setStroke()
            NSColor.labelColor.withAlphaComponent(alpha).setFill()

            let plate = NSBezierPath()
            plate.move(to: NSPoint(x: 8.5, y: 15.3))
            plate.curve(to: NSPoint(x: 9.5, y: 15.3), controlPoint1: NSPoint(x: 8.8, y: 15.5), controlPoint2: NSPoint(x: 9.2, y: 15.5))
            plate.line(to: NSPoint(x: 15.3, y: 12.4))
            plate.curve(to: NSPoint(x: 15.3, y: 11.4), controlPoint1: NSPoint(x: 15.8, y: 12.15), controlPoint2: NSPoint(x: 15.8, y: 11.65))
            plate.line(to: NSPoint(x: 9.5, y: 8.5))
            plate.curve(to: NSPoint(x: 8.5, y: 8.5), controlPoint1: NSPoint(x: 9.2, y: 8.3), controlPoint2: NSPoint(x: 8.8, y: 8.3))
            plate.line(to: NSPoint(x: 2.7, y: 11.4))
            plate.curve(to: NSPoint(x: 2.7, y: 12.4), controlPoint1: NSPoint(x: 2.2, y: 11.65), controlPoint2: NSPoint(x: 2.2, y: 12.15))
            plate.close()
            plate.fill()

            let chevrons = NSBezierPath()
            chevrons.move(to: NSPoint(x: 2.6, y: 9.0))
            chevrons.line(to: NSPoint(x: 9.0, y: 5.8))
            chevrons.line(to: NSPoint(x: 15.4, y: 9.0))

            if !hibernated {
                chevrons.move(to: NSPoint(x: 2.6, y: 5.8))
                chevrons.line(to: NSPoint(x: 9.0, y: 2.6))
                chevrons.line(to: NSPoint(x: 15.4, y: 5.8))
            }

            chevrons.lineWidth = 1.65
            chevrons.lineCapStyle = .round
            chevrons.lineJoinStyle = .round
            chevrons.stroke()

            if pressureWarning {
                let badge = NSBezierPath(ovalIn: NSRect(x: 13.5, y: 13.5, width: 3.6, height: 3.6))
                NSColor.labelColor.setFill()
                badge.fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    static func appIconImage() -> NSImage? {
        if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: icnsURL) {
            return img
        }
        if let pngURL = Bundle.main.url(forResource: "FirnIcon", withExtension: "png"),
           let img = NSImage(contentsOf: pngURL) {
            return img
        }
        let devPaths = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("assets/brand/FirnIcon.png").path,
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("../assets/brand/FirnIcon.png").standardizedFileURL.path,
            "/Applications/Firn.app/Contents/Resources/FirnIcon.png",
        ]
        for path in devPaths where FileManager.default.isReadableFile(atPath: path) {
            if let img = NSImage(contentsOfFile: path) {
                return img
            }
        }
        return nil
    }
}

struct FirnLogoBadge: View {
    var size: CGFloat = 36

    var body: some View {
        let corner = size * 0.235
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [.white, Color(red: 0.97, green: 0.97, blue: 0.98), Color(red: 0.925, green: 0.925, blue: 0.94)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            LayeredStrataMark()
                .frame(width: size * 0.78, height: size * 0.78)
        }
        .frame(width: size, height: size)
        .overlay(
            shape.strokeBorder(Color(red: 0.094, green: 0.094, blue: 0.106).opacity(0.11), lineWidth: 0.85)
        )
        .shadow(color: Color(red: 0.094, green: 0.094, blue: 0.106).opacity(0.13), radius: size * 0.12, x: 0, y: size * 0.06)
    }
}

private struct LayeredStrataMark: View {
    var body: some View {
        Canvas { ctx, sz in
            let s = min(sz.width, sz.height) / 128.0
            let ox = (sz.width - 128.0 * s) * 0.5
            let oy = (sz.height - 128.0 * s) * 0.5
            ctx.translateBy(x: ox, y: oy)
            ctx.scaleBy(x: s, y: s)

            var plate = Path()
            plate.move(to: CGPoint(x: 60.8, y: 23.6))
            plate.addCurve(to: CGPoint(x: 67.2, y: 23.6), control1: CGPoint(x: 62.8, y: 22.5), control2: CGPoint(x: 65.2, y: 22.5))
            plate.addLine(to: CGPoint(x: 103.6, y: 41.8))
            plate.addCurve(to: CGPoint(x: 103.6, y: 48.2), control1: CGPoint(x: 106.4, y: 43.2), control2: CGPoint(x: 106.4, y: 46.8))
            plate.addLine(to: CGPoint(x: 67.2, y: 66.4))
            plate.addCurve(to: CGPoint(x: 60.8, y: 66.4), control1: CGPoint(x: 65.2, y: 67.5), control2: CGPoint(x: 62.8, y: 67.5))
            plate.addLine(to: CGPoint(x: 24.4, y: 48.2))
            plate.addCurve(to: CGPoint(x: 24.4, y: 41.8), control1: CGPoint(x: 21.6, y: 46.8), control2: CGPoint(x: 21.6, y: 43.2))
            plate.closeSubpath()

            ctx.fill(
                plate,
                with: .linearGradient(
                    Gradient(colors: [Color(red: 0.094, green: 0.094, blue: 0.106), Color(red: 0.196, green: 0.196, blue: 0.227)]),
                    startPoint: CGPoint(x: 22, y: 22),
                    endPoint: CGPoint(x: 106, y: 62)
                )
            )

            let strokeStyle = StrokeStyle(lineWidth: 10.5, lineCap: .round, lineJoin: .round)

            var mid = Path()
            mid.move(to: CGPoint(x: 24, y: 64))
            mid.addLine(to: CGPoint(x: 64, y: 84))
            mid.addLine(to: CGPoint(x: 104, y: 64))
            ctx.stroke(mid, with: .color(Color(red: 0.184, green: 0.435, blue: 0.929)), style: strokeStyle)

            var bottom = Path()
            bottom.move(to: CGPoint(x: 24, y: 83))
            bottom.addLine(to: CGPoint(x: 64, y: 103))
            bottom.addLine(to: CGPoint(x: 104, y: 83))
            ctx.stroke(bottom, with: .color(Color(red: 0.784, green: 0.490, blue: 0.184)), style: strokeStyle)
        }
    }
}
