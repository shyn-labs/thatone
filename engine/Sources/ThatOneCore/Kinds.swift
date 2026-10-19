import Foundation

public enum Kinds {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tif", "tiff"]
    public static let documentExtensions: Set<String> = ["docx", "doc", "rtf", "odt"]
    public static let textExtensions: Set<String> = ["txt", "md", "html", "htm"]
    public static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "caf", "aiff", "aif"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    public static let codeExtensions: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "py", "go", "rs",
                                                     "java", "kt", "c", "h", "cc", "cpp", "hpp", "m", "mm", "rb", "php", "sh",
                                                     "bash", "zsh", "sql", "lua", "scala", "cs"]

    /// Every kind the engine can index, in the order the UI lists them.
    public static let all = ["image", "pdf", "document", "text", "audio", "video", "code"]
    /// Plain-text-like files, audio and video are opt-in: a home folder holds tens of thousands of text files (data, logs,
    /// build output), audio is slow to transcribe, and video is transcribed and has its frames cut and embedded.
    public static let defaultEnabled: Set<String> = ["image", "pdf", "document"]
    /// Kinds a search leaves out unless it names them: source code would crowd every everyday search.
    public static let hiddenByDefault: Set<String> = ["code"]

    /// The file extensions (lowercase) that `detect` maps to `kind`.
    public static func extensions(of kind: String) -> Set<String> {
        switch kind {
        case "image": return imageExtensions
        case "pdf": return ["pdf"]
        case "document": return documentExtensions
        case "text": return textExtensions
        case "audio": return audioExtensions
        case "video": return videoExtensions
        case "code": return codeExtensions
        default: return []
        }
    }

    /// The kind a file name belongs to, whether or not it is enabled; nil for anything else.
    public static func detect(_ path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return "image" }
        if ext == "pdf" { return "pdf" }
        if documentExtensions.contains(ext) { return "document" }
        if textExtensions.contains(ext) { return "text" }
        if audioExtensions.contains(ext) { return "audio" }
        if videoExtensions.contains(ext) { return "video" }
        if codeExtensions.contains(ext) { return "code" }
        return nil
    }
}
