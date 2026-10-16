import AppKit
import SwiftUI

@MainActor
public final class BigWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: BigWindowModel
    private let thumbnails: ThumbnailCache
    private let actions: FileActioning

    public init(model: BigWindowModel, thumbnails: ThumbnailCache, actions: FileActioning) {
        self.model = model; self.thumbnails = thumbnails; self.actions = actions
    }

    public func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "ThatOne"
            w.contentView = NSHostingView(rootView: BigWindowView(model: model, thumbnails: thumbnails, actions: actions))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        model.search.reset()
        NSApp.setActivationPolicy(.regular)                         // a visible window needs a Dock icon and a menu
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
}
