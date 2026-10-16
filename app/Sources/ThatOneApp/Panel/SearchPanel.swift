import AppKit

public final class SearchPanel: NSPanel {
    public var keyHandler: ((KeyPress) -> Bool)?

    public init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func resignKey() { super.resignKey(); orderOut(nil) }

    /// Panel-level shortcuts win over the text field; everything else falls through to it.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(KeyPress(event: event)) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    public override func keyDown(with event: NSEvent) {
        if keyHandler?(KeyPress(event: event)) == true { return }
        super.keyDown(with: event)
    }
}
