import Carbon.HIToolbox
import Foundation

public struct HotKeyPreset: Equatable, Identifiable {
    public let id: String
    public let label: String
    public let keyCode: UInt32
    public let modifiers: UInt32

    public static let all: [HotKeyPreset] = [
        HotKeyPreset(id: "ctrl-opt-space", label: "⌃⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
        HotKeyPreset(id: "opt-space", label: "⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
        HotKeyPreset(id: "cmd-shift-space", label: "⌘⇧Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)),
        HotKeyPreset(id: "ctrl-opt-f", label: "⌃⌥F", keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | optionKey)),
    ]
    public static let `default` = all[0]

    public static func preset(id: String?) -> HotKeyPreset { all.first { $0.id == id } ?? .default }
}

/// A global hotkey via Carbon's RegisterEventHotKey (no Accessibility permission needed).
public final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void
    private static var counter: UInt32 = 0
    public private(set) var status: OSStatus = noErr

    /// `modifiers` are Carbon masks (controlKey, optionKey, cmdKey, shiftKey).
    public init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        HotKey.counter += 1
        let id = EventHotKeyID(signature: OSType(0x54484F4E), id: HotKey.counter)      // 'THON'
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().handler()
            return noErr
        }
        status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                                     Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        if status == noErr {
            status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        }
        if status != noErr, let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }

    /// nil when registered; otherwise a sentence for the menu.
    public var registrationError: String? {
        if status == noErr { return nil }
        if status == OSStatus(eventHotKeyExistsErr) { return "already in use by another app" }
        return "could not register (code \(status))"
    }

    public func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        ref = nil
        handlerRef = nil
    }

    deinit { unregister() }
}
