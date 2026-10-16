import AppKit

public enum ShowInPhotos {
    /// The AppleScript that selects one photo in the Photos app. The identifier is quoted and escaped.
    public static func script(forAssetID id: String) -> String {
        let escaped = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Photos"
            activate
            spotlight media item id "\(escaped)"
        end tell
        """
    }

    /// Runs the script off the main thread. `completion` gets a readable message on failure, nil on success.
    public static func show(assetID: String, completion: ((String?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            NSAppleScript(source: script(forAssetID: assetID))?.executeAndReturnError(&errorInfo)
            let message = errorInfo.map { _ in "Allow ThatOne to control Photos in System Settings > Privacy & Security > Automation." }
            DispatchQueue.main.async { completion?(message) }
        }
    }
}
