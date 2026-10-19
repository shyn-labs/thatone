import SwiftUI

struct SearchPanelView: View {
    @ObservedObject var model: SearchModel
    let thumbnails: ThumbnailCache
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            SearchingBar(active: model.isSearching)
            if let heading = model.heading {
                Label(heading, systemImage: "sparkles").font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.top, 8)
            }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.top, 8)
            }
            ZStack {
                HStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                    ResultRowView(row: row, selected: index == model.selection, thumbnails: thumbnails).id(row.id)   // identity = the file, so a new result list redraws
                                }
                            }
                            .padding(8)
                            .opacity(model.isSearching ? 0.55 : 1)
                            .animation(.easeOut(duration: 0.15), value: model.isSearching)
                        }
                        .onChange(of: model.selection) { _, new in if model.rows.indices.contains(new) { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(model.rows[new].id) } } }
                    }
                    if model.previewVisible, let row = model.selectedRow {
                        Divider().opacity(0.5)
                        PreviewView(row: row, thumbnails: thumbnails).frame(width: 300).transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                if model.rows.isEmpty && !model.isSearching { emptyState }
            }
            .animation(.easeOut(duration: 0.15), value: model.previewVisible)
            footer
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear { focused = true }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium)).foregroundStyle(Color.accentColor)
            TextField("Describe the file you remember…", text: model.queryBinding)
                .textFieldStyle(.plain).font(.system(size: 22, weight: .light)).focused($focused)
                .accessibilityIdentifier("thatone.query")
            if model.isSearching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(.caption).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            Text(model.kind.title).font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.15), in: Capsule()).foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.query.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass").font(.system(size: 34, weight: .thin))
            Text(model.query.isEmpty ? "Nothing indexed yet" : "No matches").font(.callout)
        }
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↩", "open"); hint("⌘↩", "reveal"); hint("⌘⇧C", "copy path"); hint("⌘G", "more like this"); hint("⇥", "filter"); hint("space", "preview")
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.06))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .rounded)).padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct ResultRowView: View {
    let row: ResultRow
    let selected: Bool
    let thumbnails: ThumbnailCache
    @State private var image: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary)
                if let image { Image(decorative: image, scale: 2).resizable().scaledToFill().transition(.opacity) }
            }
            .frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if row.kind != "image" { Image(systemName: KindIcon.name(for: row.kind)).font(.system(size: 11)).foregroundStyle(.secondary) }
                    Text(row.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                }
                Text(row.folder).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                switch row.why {
                case .snippet(let text):
                    Label(text, systemImage: "text.quote").font(.system(size: 11)).foregroundStyle(Color.accentColor).lineLimit(1)
                case .visual:
                    Label("matches what the picture shows", systemImage: "sparkles").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                case .none:
                    EmptyView()
                }
            }
            Spacer(minLength: 8)
            ForEach(row.chips, id: \.self) {
                Text($0).font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1))
            }
        }
        .contentShape(Rectangle())
        .task(id: row.id) {
            let loaded = await thumbnails.thumbnail(path: row.path, modified: Int64(row.modified?.timeIntervalSince1970 ?? 0), side: 116)
            withAnimation(.easeIn(duration: 0.15)) { image = loaded }
        }
    }
}

struct PreviewView: View {
    let row: ResultRow
    let thumbnails: ThumbnailCache
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 10) {
            if row.kind == "audio" {
                AudioPreviewView(row: row)
            } else if row.kind == "video" {
                VideoPreviewView(row: row, thumbnail: image)
            } else if row.kind == "code" {
                CodePreviewView(row: row)
            } else if row.kind == "pdf" {
                PDFPageView(path: row.path, page: row.page ?? 1)
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                if let page = row.page { Text("Page \(page)").font(.caption.weight(.medium)).foregroundStyle(Color.accentColor) }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary)
                    if let image { Image(decorative: image, scale: 2).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)) }
                }
                .frame(maxWidth: .infinity, maxHeight: row.kind == "image" ? 250 : 120).shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                if row.kind != "image", !row.excerpt.isEmpty {
                    ScrollView { Text(row.excerpt).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 150)
                }
            }
            Text(row.name).font(.system(size: 14, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
            Text(row.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            if !row.otherPaths.isEmpty { Text("+\(row.otherPaths.count) other copies").font(.caption).foregroundStyle(.secondary) }
            if let date = row.modified { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(14)
        .task(id: row.id) {
            image = await thumbnails.thumbnail(path: row.path, modified: Int64(row.modified?.timeIntervalSince1970 ?? 0), side: 600)
        }
    }
}

/// A thin line under the search field: a plain divider at rest, a sweeping bar while a search runs.
struct SearchingBar: View {
    let active: Bool
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.primary.opacity(0.08))
                if active {
                    Rectangle().fill(LinearGradient(colors: [.clear, Color.accentColor, .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * 0.3).offset(x: geo.size.width * phase)
                }
            }
            .clipped()
            .onChange(of: active) { _, on in
                phase = -0.3
                if on { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { phase = 1.0 } }
            }
        }
        .frame(height: 2)
    }
}
