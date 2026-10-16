import Foundation
import ThatOneCore

/// The "What to index" switches in Settings.
struct KindSwitch: Identifiable {
    let kind: String
    let title: String
    let note: String?
    var id: String { kind }

    static let all = [
        KindSwitch(kind: "image", title: "Images", note: nil),
        KindSwitch(kind: "pdf", title: "PDFs", note: nil),
        KindSwitch(kind: "document", title: "Documents (docx, doc, rtf, odt)", note: nil),
        KindSwitch(kind: "audio", title: "Audio (transcribed on this Mac)", note: "Needs the Whisper model; can take hours for a large library."),
        KindSwitch(kind: "video", title: "Video (frames and soundtrack)", note: "Needs the Whisper model; frames are sampled every few seconds and the sound is transcribed; can take hours for a large library."),
        KindSwitch(kind: "text", title: "Text-like files (txt, md, html)", note: "Can add tens of thousands of files, mostly data and notes inside projects."),
    ]

    /// `kinds` with `kind` switched on or off; unknown names never get in.
    static func toggled(_ kinds: Set<String>, _ kind: String, on: Bool) -> Set<String> {
        guard Kinds.all.contains(kind) else { return kinds }
        var next = kinds
        if on { next.insert(kind) } else { next.remove(kind) }
        return next
    }
}
