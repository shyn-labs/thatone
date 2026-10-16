import AppKit

@MainActor
public final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let hotKey: () -> HotKeyPreset
    private var actions: [String: () -> Void]
    private var latest = HostSnapshot()

    public init(hotKey: @escaping () -> HotKeyPreset, actions: [String: () -> Void]) {
        self.hotKey = hotKey
        self.actions = actions
        super.init()
        item.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "ThatOne")
        update(latest)
    }

    public func update(_ snapshot: HostSnapshot) {
        latest = snapshot
        let paused: Bool
        switch snapshot.state { case .pausedByUser, .paused: paused = true; default: paused = false }
        item.button?.appearsDisabled = paused
        let menu = NSMenu()
        for spec in MenuModel.items(for: snapshot, hotKey: hotKey()) {
            let entry = NSMenuItem(title: spec.title, action: spec.enabled ? #selector(chosen(_:)) : nil, keyEquivalent: spec.id == "quit" ? "q" : "")
            entry.target = self
            entry.representedObject = spec.id
            entry.isEnabled = spec.enabled
            menu.addItem(entry)
            if spec.id == "status" || spec.id == "window" { menu.addItem(.separator()) }
        }
        item.menu = menu
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        actions[id]?()
    }
}
