import SwiftUI

struct FailedFilesView: View {
    let files: [(path: String, note: String)]
    let retryAll: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(files.indices, id: \.self) { i in
                VStack(alignment: .leading) { Text(files[i].path).lineLimit(1).truncationMode(.middle); Text(files[i].note).font(.caption).foregroundStyle(.secondary) }
            }
            Button("Retry all", action: retryAll).padding(.horizontal)
        }
        .frame(width: 520, height: 320).padding(.vertical, 8)
    }
}
