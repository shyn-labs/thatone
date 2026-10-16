import PDFKit
import SwiftUI

/// Shows one page of a PDF (the page a match is on). Display only: all reading and indexing happens in the engine.
struct PDFPageView: NSViewRepresentable {
    let path: String
    let page: Int

    final class Coordinator { var loadedPath: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.autoScales = true
        view.displaysPageBreaks = false
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.loadedPath != path {
            context.coordinator.loadedPath = path
            view.document = PDFDocument(url: URL(fileURLWithPath: path))
        }
        if let document = view.document, document.pageCount > 0, let target = document.page(at: min(max(page, 1), document.pageCount) - 1) {
            view.go(to: target)
        }
    }
}

/// A file icon for the kind of result.
enum KindIcon {
    static func name(for kind: String) -> String {
        switch kind {
        case "pdf": return "doc.richtext"
        case "document": return "doc.text"
        case "text": return "text.alignleft"
        case "audio": return "waveform"
        case "video": return "film"
        default: return "photo"
        }
    }
}
