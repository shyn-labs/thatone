import Foundation

public struct MenuItemSpec: Equatable {
    public let id: String
    public let title: String
    public var enabled = true
}

public enum MenuModel {
    public static func items(for s: HostSnapshot, hotKey: HotKeyPreset) -> [MenuItemSpec] {
        let search = s.hotKeyProblem.map { "Search (hotkey unavailable: \($0))" } ?? "Search  \(hotKey.label)"
        let images = s.files["indexed"] ?? 0
        let status: String
        switch s.state {
        case .starting: status = "Starting…"
        case .idle: status = "Up to date · \(images) images"
        case .indexing(let done, let waiting): status = "Indexing \(done) of \(done + waiting)"
        case .pausedByUser: status = "Paused by you"
        case .paused(let reason): status = "Paused: \(reason)"
        }
        var items = [MenuItemSpec(id: "open", title: search),
                     MenuItemSpec(id: "status", title: status, enabled: false),
                     MenuItemSpec(id: "pause", title: s.state == .pausedByUser ? "Resume indexing" : "Pause indexing"),
                     MenuItemSpec(id: "window", title: "Browse all…")]
        var extras: [MenuItemSpec] = []
        let pdfs = s.kinds["pdf", default: 0], documents = s.kinds["document", default: 0]
        let recordings = s.kinds["audio", default: 0]
        if recordings > 0 {
            extras.append(MenuItemSpec(id: "recordings", title: "\(recordings) \(recordings == 1 ? "recording" : "recordings")", enabled: false))
        }
        let videos = s.kinds["video", default: 0]
        if videos > 0 {
            extras.append(MenuItemSpec(id: "videos", title: "\(videos) \(videos == 1 ? "video" : "videos")", enabled: false))
        }
        let code = s.kinds["code", default: 0]
        if code > 0 {
            extras.append(MenuItemSpec(id: "code", title: "\(code) code \(code == 1 ? "file" : "files")", enabled: false))
        }
        if pdfs + documents > 0 {
            extras.append(MenuItemSpec(id: "kinds", title: "\(pdfs) \(pdfs == 1 ? "PDF" : "PDFs"), \(documents) \(documents == 1 ? "document" : "documents")", enabled: false))
        }
        if s.audio == .modelMissing { extras.append(MenuItemSpec(id: "audio", title: "Audio: Whisper model not found", enabled: false)) }
        switch s.photos {
        case .off: break
        case .needsPermission: extras.append(MenuItemSpec(id: "photos", title: "Apple Photos: needs permission…"))
        case .denied: extras.append(MenuItemSpec(id: "photos", title: "Apple Photos: access denied (open Settings)…"))
        case .restricted: extras.append(MenuItemSpec(id: "photos", title: "Apple Photos: restricted on this Mac", enabled: false))
        case .on(let limited):
            extras.append(MenuItemSpec(id: "photos", title: "Apple Photos: \(s.photosCount) photos" + (limited ? " (limited access)" : ""),
                                       enabled: false))
        }
        items.insert(contentsOf: extras, at: 2)
        if s.queue.failed > 0 {
            items.append(MenuItemSpec(id: "failed", title: "\(s.queue.failed) \(s.queue.failed == 1 ? "file" : "files") could not be indexed…"))
        }
        items += [MenuItemSpec(id: "folders", title: "Folders…"), MenuItemSpec(id: "settings", title: "Settings…"),
                  MenuItemSpec(id: "quit", title: "Quit ThatOne")]
        return items
    }
}

public enum FolderCandidates {
    public static func existing(home: String, fileManager: FileManager = .default) -> [String] {
        ["Pictures", "Desktop", "Downloads", "Documents"].map { "\(home)/\($0)" }.filter {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
