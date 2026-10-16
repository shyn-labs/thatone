import AppKit

public struct KeyPress: Equatable {
    public var key: String
    public var command = false, shift = false, option = false, control = false
    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key; self.command = command; self.shift = shift; self.option = option; self.control = control
    }

    public init(event: NSEvent) {
        let names: [UInt16: String] = [126: "up", 125: "down", 36: "return", 76: "return", 53: "escape", 49: "space", 48: "tab"]
        key = names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").lowercased()
        command = event.modifierFlags.contains(.command)
        shift = event.modifierFlags.contains(.shift)
        option = event.modifierFlags.contains(.option)
        control = event.modifierFlags.contains(.control)
    }
}

public func command(for p: KeyPress, queryIsEmpty: Bool) -> Command? {
    if p.control || p.option { return nil }
    switch (p.key, p.command, p.shift) {
    case ("up", false, false): return .up
    case ("down", false, false): return .down
    case ("return", false, false): return .open
    case ("return", true, false): return .reveal
    case ("c", true, true): return .copyPath
    case ("y", true, false): return .preview
    case ("space", false, false): return queryIsEmpty ? .preview : nil
    case ("g", true, false): return .moreLike
    case ("tab", false, false): return .cycleKind
    case ("escape", false, false): return .close
    default: return nil
    }
}
