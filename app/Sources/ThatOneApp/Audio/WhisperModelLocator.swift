import Foundation

/// Finds a Whisper model on disk. ThatOne never downloads one: it reuses the folder shyn already keeps, or one the
/// user named in the config.
public enum WhisperModelLocator {
    public static let shynRoot = NSHomeDirectory() + "/Library/Application Support/shyn/models/whisperkit"
    /// Fastest first: the turbo model is what shyn uses; the others are fallbacks.
    static let preferred = ["openai_whisper-large-v3_turbo", "openai_whisper-small", "openai_whisper-large-v3"]

    /// `configured` is `Config.whisperFolder`: either a model folder itself (it holds `AudioEncoder.mlmodelc`) or a
    /// WhisperKit root that holds `models/argmaxinc/whisperkit-coreml/<model>`.
    public static func find(configured: String?, shynRoot: String = shynRoot, fileManager: FileManager = .default) -> URL? {
        for root in [configured, shynRoot].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            let url = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
            if isModelFolder(url, fileManager) { return url }
            let models = url.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            for name in preferred {
                let candidate = models.appendingPathComponent(name)
                if isModelFolder(candidate, fileManager) { return candidate }
            }
        }
        return nil
    }

    static func isModelFolder(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.appendingPathComponent("AudioEncoder.mlmodelc").path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

public enum AudioState: Equatable {
    case off
    case modelMissing
    case ready
}
