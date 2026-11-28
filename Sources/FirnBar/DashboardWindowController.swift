import AppKit
import SwiftUI

@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    private let store: FirnStore

    init(store: FirnStore) {
        self.store = store
        let hosting = NSHostingView(rootView: FirnControlCenterView(store: store))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Firn"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 960, height: 620)
        window.contentView = hosting
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndActivate() {
        NSApp.setActivationPolicy(.regular)
        if let icon = FirnBrandMark.appIconImage() {
            NSApp.applicationIconImage = icon
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        store.refreshDockerInventory()
        store.onRequestRefresh?()
    }

    func windowWillClose(_ notification: Notification) {
        store.closeLogsSheet()
        NSApp.setActivationPolicy(.accessory)
    }
}
