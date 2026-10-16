import AppKit
import ThatOneCore

public final class FileActions: FileActioning {
    private let workspace: NSWorkspace
    private let pasteboard: NSPasteboard
    private let showInPhotos: (String) -> Void

    public init(workspace: NSWorkspace = .shared, pasteboard: NSPasteboard = .general,
                showInPhotos: @escaping (String) -> Void = { ShowInPhotos.show(assetID: $0) }) {
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.showInPhotos = showInPhotos
    }

    // A photo from Apple Photos is not a file: opening and revealing both select it in the Photos app.
    public func open(_ path: String) {
        if let photo = PhotosPath.parse(path) { showInPhotos(photo.id); return }
        workspace.open(URL(fileURLWithPath: path))
    }
    public func reveal(_ path: String) {
        if let photo = PhotosPath.parse(path) { showInPhotos(photo.id); return }
        workspace.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    public func copyPath(_ path: String) {
        pasteboard.clearContents()
        pasteboard.setString(PhotosPath.parse(path).map { "\($0.filename) (Apple Photos)" } ?? path, forType: .string)
    }
}
