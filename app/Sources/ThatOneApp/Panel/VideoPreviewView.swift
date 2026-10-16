import AVFoundation
import AVKit
import SwiftUI
import ThatOneCore

/// Plays the selected video from where it matched. Never auto-plays, never runs beside an audio clip, and a Photos
/// virtual path never reaches AVPlayer. Stops when the selection changes, the preview closes or the panel hides.
final class VideoPlayback: ObservableObject {
    static let shared = VideoPlayback(player: AVClipPlayer(), audio: .shared)
    private let player: ClipPlayer
    private let audio: AudioPlayback
    @Published private(set) var playingPath: String?
    @Published private(set) var shownPath: String?          // the row whose player view is on screen (playing or paused)

    init(player: ClipPlayer, audio: AudioPlayback) {
        self.player = player
        self.audio = audio
        audio.willStart = { [weak self] in if self?.shownPath != nil { self?.stop() } }
    }

    static func canPlay(path: String) -> Bool { !PhotosPath.isPhotos(path) && path.hasPrefix("/") }

    func toggle(path: String, from seconds: Double) {
        guard Self.canPlay(path: path) else { return }
        if playingPath == path { player.pause(); playingPath = nil }
        else { audio.stop(); player.play(path: path, from: seconds); playingPath = path; shownPath = path }
    }

    func stop() { player.stop(); playingPath = nil; shownPath = nil }
    func isPlaying(_ path: String) -> Bool { playingPath == path }
    /// The real player for the view; nil with a test double.
    var avPlayer: AVPlayer? { (player as? AVClipPlayer)?.avPlayer }
}

enum PlaybackStopper {
    static func stopAll(audio: AudioPlayback, video: VideoPlayback) { audio.stop(); video.stop() }
}

/// A thin wrapper; only created for the selected video row after Play was pressed.
struct AVPlayerSurface: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}

struct VideoPreviewView: View {
    let row: ResultRow
    let thumbnail: CGImage?
    @ObservedObject private var playback = VideoPlayback.shared

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary)
                if playback.shownPath == row.path {
                    AVPlayerSurface(player: playback.avPlayer).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if let thumbnail {
                    Image(decorative: thumbnail, scale: 2).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "film").font(.system(size: 34)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 200).shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            if VideoPlayback.canPlay(path: row.path) {
                Button {
                    playback.toggle(path: row.path, from: row.startTime ?? 0)
                } label: {
                    Label(playback.isPlaying(row.path) ? "Pause" : "Play" + (row.chips.first.map { " from \($0)" } ?? ""),
                          systemImage: playback.isPlaying(row.path) ? "pause.fill" : "play.fill")
                }
            }
            if !row.excerpt.isEmpty {
                ScrollView { Text(row.excerpt).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 150)
            }
        }
        .onChange(of: row.id) { _ in playback.stop() }
        .onDisappear { playback.stop() }
    }
}
