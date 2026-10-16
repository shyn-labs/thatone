import Foundation

/// What a key press or a menu choice asks the search UI to do.
public enum Command: Equatable {
    case up, down, open, reveal, copyPath, moreLike, preview, cycleKind, close
}

public enum KindFilter: String, CaseIterable {
    case all, image, pdf, document, audio, video

    public var kinds: [String] { self == .all ? [] : [rawValue] }
    public var title: String {
        switch self { case .all: "All"; case .image: "Images"; case .pdf: "PDFs"; case .document: "Documents"; case .audio: "Audio"; case .video: "Video" }
    }
    public func next() -> KindFilter {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

public protocol FileActioning: AnyObject {
    func open(_ path: String)
    func reveal(_ path: String)
    func copyPath(_ path: String)
}
