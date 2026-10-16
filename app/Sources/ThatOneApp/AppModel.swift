import AppKit
import SwiftUI
import ThatOneCore

/// Everything the running app is made of, wired together. The models are built in `init` (so tests can use them
/// without a window system); windows, the menu-bar item and the hotkey exist only after `installUI()`.
public final class AppModel {
    public static let uiActions: Set<String> = ["show_panel", "hide_panel", "show_window", "settings", "quit"]

    public let engine: Engine
    public let host: EngineHost
    public let search: SearchModel
    public let bigWindow: BigWindowModel
    /// A test seam: when set, UI actions go here instead of to the controllers.
    public var windowHooks: ((String) -> Void)?

    private let home: String
    private let registersHotKey: Bool
    private let thumbnails: ThumbnailCache
    private let actions = FileActions()
    private var panel: PanelController?
    private var bigWindowController: BigWindowController?
    private var menu: MenuBarController?
    private var hotKey: HotKey?
    private var windows: [String: NSWindow] = [:]
    private var preset: HotKeyPreset

    private final class Relay { var target: ((HostSnapshot) -> Void)? }

    @MainActor
    public init(engine: Engine, home: String = NSHomeDirectory(), power: @escaping () -> String? = PowerPolicy.currentReason,
                registersHotKey: Bool = true, photos: AssetProvider? = nil, realPhotoKit: Bool = false,
                memory: MemoryPressureSource = SystemMemoryPressure(), speech: SpeechSession? = nil) {
        let relay = Relay()
        self.engine = engine
        self.home = home
        self.registersHotKey = registersHotKey
        self.preset = HotKeyPreset.preset(id: engine.config.hotKey)
        thumbnails = ThumbnailCache(generator: ThumbnailCache.routed(photos: photos))
        host = EngineHost(engine: engine, power: power, memory: memory, assets: photos,
                          requestPhotosAccess: realPhotoKit ? { PhotosAccess.request(completion: $0) } : nil,
                          makePhotosWatcher: realPhotoKit ? { PhotosChangeWatcher(onChange: $0).asWatching() } : nil,
                          audioAvailable: speech.map { session in { session.isAvailable } },
                          onChange: { relay.target?($0) })
        search = SearchModel(engine: host, actions: actions, home: home)
        bigWindow = BigWindowModel(search: search, folders: { [weak host] in host?.snapshot.folders ?? [] })
        relay.target = { [weak self] snapshot in MainActor.assumeIsolated { self?.menu?.update(snapshot) } }
        host.uiHandler = { [weak self] action in try self?.handleUI(action) }
    }

    public var needsWelcome: Bool { engine.config.folders.isEmpty }
    public var currentPreset: HotKeyPreset { preset }

    public func savedHotKeyID() throws -> String? { try Config.load(from: engine.paths.config).hotKey }

    // MARK: UI actions (from the menu, the hotkey and the socket)

    /// Called from any thread (the socket's workers included): validates, then acts on the main thread.
    public func handleUI(_ action: String) throws {
        guard Self.uiActions.contains(action) else { throw ServiceError.unsupported("unknown ui action '\(action)'") }
        if let hook = windowHooks { hook(action); return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.perform(action) } }
    }

    @MainActor
    private func perform(_ action: String) {
        switch action {
        case "show_panel": panel?.show()
        case "hide_panel": panel?.hide()
        case "show_window": bigWindowController?.show()
        case "settings": showSettings()
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    // MARK: start-up

    @MainActor
    public func installUI() {
        let panel = PanelController(model: search, thumbnails: thumbnails)
        self.panel = panel
        bigWindowController = BigWindowController(model: bigWindow, thumbnails: thumbnails, actions: actions)
        menu = MenuBarController(hotKey: { [weak self] in self?.preset ?? .default }, actions: [
            "open": { [weak self] in self?.panel?.show() },
            "pause": { [weak self] in self?.togglePause() },
            "window": { [weak self] in self?.bigWindowController?.show() },
            "failed": { [weak self] in self?.showFailedFiles() },
            "folders": { [weak self] in self?.showSettings() },
            "settings": { [weak self] in self?.showSettings() },
            "photos": { [weak self] in self?.photosMenuAction() },
            "quit": { NSApp.terminate(nil) },
        ])
        menu?.update(host.snapshot)
        registerHotKey()
    }

    @MainActor
    public func start() { host.start() }

    @MainActor
    public func showWelcomeIfNeeded() {
        guard needsWelcome else { return }
        let candidates = FolderCandidates.existing(home: home)
        present("welcome", title: "Welcome to ThatOne", WelcomeView(candidates: candidates, start: { [weak self] folders, includePhotos in
            self?.windows["welcome"]?.close()
            if includePhotos { self?.host.setPhotos(true) }
            DispatchQueue.global().async { _ = try? self?.host.index(folders: folders) }
        }))
    }

    // MARK: hotkey

    @MainActor
    private func registerHotKey() {
        hotKey?.unregister()
        hotKey = nil
        guard registersHotKey else { return }
        let key = HotKey(keyCode: preset.keyCode, modifiers: preset.modifiers) { [weak self] in
            MainActor.assumeIsolated { self?.panel?.toggle() }
        }
        hotKey = key
        host.setHotKeyProblem(key.registrationError)
    }

    @MainActor
    public func setHotKey(_ new: HotKeyPreset) {
        preset = new
        try? engine.setHotKey(new.id)
        registerHotKey()
        menu?.update(host.snapshot)
    }

    // MARK: windows

    /// The menu's Apple Photos line: ask for permission, or open the privacy settings after a refusal.
    @MainActor
    private func photosMenuAction() {
        switch host.snapshot.photos {
        case .needsPermission: host.setPhotos(true)
        case .denied: PhotosAccess.openSettings()
        default: break
        }
    }

    @MainActor
    private func togglePause() {
        if host.snapshot.state == .pausedByUser { host.resume() } else { host.pause() }
    }

    @MainActor
    private func present<V: View>(_ key: String, title: String, _ view: V) {
        let window = windows[key] ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            windows[key] = w
            return w
        }()
        window.title = title
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func showFailedFiles() {
        let files = host.snapshot.failedFiles.map { (path: $0.path, note: $0.note) }
        present("failed", title: "Files ThatOne could not index", FailedFilesView(files: files, retryAll: { [weak self] in
            DispatchQueue.global().async { try? self?.host.retryFailed() }
            self?.windows["failed"]?.close()
        }))
    }

    @MainActor
    private func showSettings() { present("settings", title: "ThatOne settings", SettingsView(model: self)) }

    // MARK: settings support

    public var exclusions: [String] { engine.config.exclude }

    public func removeFolder(_ path: String) {
        DispatchQueue.global().async { [weak self] in try? self?.host.removeFolder(path) }
    }

    public func removeExclusion(_ path: String) { try? engine.removeExclusion(path) }

    public func shutdown() {
        hotKey?.unregister()
        host.stop()
    }
}
