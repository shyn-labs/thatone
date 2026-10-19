import Foundation

/// What a key press or a menu choice asks the search UI to do.
public enum Command: Equatable {
    case up, down, open, reveal, copyPath, moreLike, preview, cycleKind, close
}

public enum KindFilter: String, CaseIterable {
    case all, image, pdf, document, audio, video, code

    public var kinds: [String] { self == .all ? [] : [rawValue] }
    public var title: String {
        switch self { case .all: "All"; case .image: "Images"; case .pdf: "PDFs"; case .document: "Documents"; case .audio: "Audio"; case .video: "Video"; case .code: "Code" }
    }
    public func next() -> KindFilter {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

public protocol FileActioning: AnyObject {
    /// Code opens at `line` in the chosen editor; everything else in its default app. false when nothing could open it.
    @discardableResult func open(_ path: String, kind: String, line: Int?) -> Bool
    func reveal(_ path: String)
    func copyPath(_ path: String)
}

extension FileActioning {
    /// Opens in the default app (or Photos).
    @discardableResult public func open(_ path: String) -> Bool { open(path, kind: "", line: nil) }
}
