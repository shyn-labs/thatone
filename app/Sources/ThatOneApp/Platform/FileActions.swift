import AppKit
import ThatOneCore

/// The parts of NSWorkspace FileActions uses; tests pass a fake, so no app is ever launched by a test.
public protocol Workspacing: AnyObject {
    func open(_ url: URL) -> Bool
    func urlForApplication(toOpen url: URL) -> URL?
    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL?
    func activateFileViewerSelecting(_ fileURLs: [URL])
}

extension NSWorkspace: Workspacing {}

public final class FileActions: FileActioning {
    private let workspace: Workspacing
    private let pasteboard: NSPasteboard
    private let showInPhotos: (String) -> Void
    private let editor: () -> String?

    public init(workspace: Workspacing = NSWorkspace.shared, pasteboard: NSPasteboard = .general,
                showInPhotos: @escaping (String) -> Void = { ShowInPhotos.show(assetID: $0) },
                editor: @escaping () -> String? = { nil }) {
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.showInPhotos = showInPhotos
        self.editor = editor
    }

    // A photo from Apple Photos is not a file: opening and revealing both select it in the Photos app. Code opens at its
    // line in the chosen editor when that editor answers its link; otherwise (or when it fails) in the default app.
    @discardableResult
    public func open(_ path: String, kind: String, line: Int?) -> Bool {
        if let photo = PhotosPath.parse(path) { showInPhotos(photo.id); return true }
        if kind == "code" {
            let choice = Editor.resolve(editor(), isInstalled: { [workspace] in workspace.urlForApplication(withBundleIdentifier: $0) != nil })
            if let link = Editor.link(editor: choice, path: path, line: line ?? 1),
               workspace.urlForApplication(toOpen: link) != nil, workspace.open(link) {
                return true
            }
        }
        return workspace.open(URL(fileURLWithPath: path))
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
