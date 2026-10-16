import SwiftUI

struct WelcomeView: View {
    let candidates: [String]
    let start: ([String], Bool) -> Void
    @State private var chosen: Set<String> = []
    @State private var includePhotos = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find that one file").font(.title2.bold())
            Text("ThatOne reads your images on this Mac so you can find them by describing them. Nothing leaves your Mac.")
            ForEach(candidates, id: \.self) { path in
                Toggle(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), isOn: Binding(
                    get: { chosen.contains(path) },
                    set: { on in if on { chosen.insert(path) } else { chosen.remove(path) } }))
            }
            Toggle("Include my Apple Photos", isOn: $includePhotos)
            if includePhotos { Text("macOS will ask once for permission to read your photos. Hidden and Recently Deleted photos are never read.").font(.caption).foregroundStyle(.secondary) }
            Button("Start indexing") { start(Array(chosen), includePhotos) }.disabled(chosen.isEmpty && !includePhotos).keyboardShortcut(.defaultAction)
        }
        .padding(24).frame(width: 460)
        .onAppear { chosen = Set(candidates.prefix(1)) }
    }
}
