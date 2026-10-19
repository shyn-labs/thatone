import AppKit
import SwiftUI

struct BigWindowView: View {
    @ObservedObject var model: BigWindowModel
    let thumbnails: ThumbnailCache
    let actions: FileActioning

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Describe it…", text: model.search.queryBinding).textFieldStyle(.roundedBorder)
                Picker("Kind", selection: model.search.kindBinding) { ForEach(KindFilter.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(width: 110)
                Picker("Folder", selection: model.search.folderBinding) {
                    Text("All folders").tag(String?.none)
                    ForEach(model.folders, id: \.self) { Text($0.replacingOccurrences(of: NSHomeDirectory(), with: "~")).tag(String?.some($0)) }
                }.frame(width: 170)
                Picker("When", selection: model.sinceBinding) { ForEach(SinceFilter.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(width: 130)
                Picker("Sort", selection: $model.sortOrder) {
                    Text("Automatic").tag(SortOrder?.none)
                    ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(SortOrder?.some($0)) }
                }.frame(width: 130)
            }.padding(10)
            if let notice = model.search.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(model.visibleRows) { row in
                        GridCell(row: row, thumbnails: thumbnails)
                            .onTapGesture(count: 2) { model.search.open(row) }
                            .contextMenu {
                                Button("Open") { model.search.open(row) }
                                Button("Reveal in Finder") { actions.reveal(row.path) }
                                Button("Copy path") { actions.copyPath(row.path) }
                            }
                    }
                }.padding(12)
            }
        }
    }
}

private struct GridCell: View {
    let row: ResultRow
    let thumbnails: ThumbnailCache
    @State private var image: CGImage?
    var body: some View {
        VStack {
            Group { if let image { Image(decorative: image, scale: 2).resizable().scaledToFill() } else { Color.secondary.opacity(0.15) } }
                .frame(width: 140, height: 110).clipShape(RoundedRectangle(cornerRadius: 8))
            Text(row.name).font(.caption).lineLimit(1)
        }
        .task(id: row.id) { image = await thumbnails.thumbnail(path: row.path, modified: Int64(row.modified?.timeIntervalSince1970 ?? 0), side: 280) }
    }
}
