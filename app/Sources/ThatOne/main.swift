import AppKit
import ThatOneApp

if CommandLine.arguments.contains("--version") {
    print("ThatOne \(AppVersion.string)")
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)          // a menu-bar app: no Dock icon, no main menu
let delegate = AppDelegate()
app.delegate = delegate
app.run()
