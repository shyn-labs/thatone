import AppKit
import ThatOneCore

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var server: LineSocketServer?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let paths = Paths.current(environment: environment)

        // One instance: a second launch asks the first to show its panel and leaves.
        if let running = RemoteEngineService.ifRunning(socketPath: paths.socket.path) {
            try? running.ui(action: "show_panel")
            exit(0)
        }

        let photos = PhotoKitProvider()
        let engine: Engine
        let speech: SpeechSession
        do {
            let config = try Config.load(from: paths.config)
            speech = SpeechSession.whisperKit(configuredFolder: { config.whisperFolder })
            engine = try Engine(paths: paths, config: config,
                                keyProvider: Keys.provider(environment: environment), assets: photos, transcriber: speech)
        } catch {
            fail("ThatOne could not open its index: \(error)")
            return
        }
        let model = AppModel(engine: engine, registersHotKey: environment["THATONE_NO_HOTKEY"] != "1", photos: photos, realPhotoKit: true, speech: speech)
        self.model = model
        do { server = try ServiceSocket.start(path: paths.socket.path, service: model.host) }
        catch SocketError.alreadyRunning { exit(0) }
        catch { fail("ThatOne could not open its control socket: \(error)"); return }
        model.installUI()
        model.start()
        model.showWelcomeIfNeeded()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        model?.shutdown()
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ThatOne cannot start"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}
