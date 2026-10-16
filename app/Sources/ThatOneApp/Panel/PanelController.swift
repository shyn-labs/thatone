import AppKit
import SwiftUI

@MainActor
public final class PanelController {
    private let model: SearchModel
    private let panel: SearchPanel

    public init(model: SearchModel, thumbnails: ThumbnailCache) {
        self.model = model
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500))
        panel.contentView = NSHostingView(rootView: SearchPanelView(model: model, thumbnails: thumbnails))
        panel.keyHandler = { [weak self] press in self?.handle(press) ?? false }
        model.onActivated = { [weak self] in self?.hide() }
    }

    public var isVisible: Bool { panel.isVisible }

    public func toggle() { isVisible ? hide() : show() }

    public func show() {
        model.reset()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.maxY - panel.frame.height - screen.height * 0.18))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func hide() { PlaybackStopper.stopAll(audio: .shared, video: .shared); panel.orderOut(nil) }

    private func handle(_ press: KeyPress) -> Bool {
        guard let command = command(for: press, queryIsEmpty: model.query.isEmpty) else { return false }
        if command == .close { hide() } else { model.perform(command) }
        return true
    }
}
