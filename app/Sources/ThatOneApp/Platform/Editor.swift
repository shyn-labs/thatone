import Foundation
import ThatOneCore

/// Which editor opens code results, and the link that opens a file at a line in it.
public enum Editor {
    public static let vscodeBundleID = "com.microsoft.VSCode"

    /// The configured choice; with none (or an unknown one), VS Code when it is installed, else the default app.
    public static func resolve(_ setting: String?, isInstalled: (String) -> Bool) -> String {
        if let setting, Config.editors.contains(setting) { return setting }
        return isInstalled(vscodeBundleID) ? "vscode" : "default"
    }

    /// `vscode://file/<path>:<line>` or `zed://file/<path>:<line>`; nil for the default app.
    public static func link(editor: String, path: String, line: Int) -> URL? {
        let scheme: String
        switch editor {
        case "vscode": scheme = "vscode"
        case "zed": scheme = "zed"
        default: return nil
        }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: ":"))
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(scheme)://file\(encoded):\(max(line, 1))")
    }
}
