import AVFoundation
import SwiftUI

/// The part of AVPlayer the controller needs, so tests never open an audio device.
protocol ClipPlayer: AnyObject {
    func play(path: String, from seconds: Double)
    func pause()
    func stop()
    var currentTime: Double { get }
}

final class AVClipPlayer: ClipPlayer {
    private var player: AVPlayer?
    var avPlayer: AVPlayer? { player }
    func play(path: String, from seconds: Double) {
        if player == nil || (player?.currentItem?.asset as? AVURLAsset)?.url.path != path {
            player = AVPlayer(url: URL(fileURLWithPath: path))
        }
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
    }
    func pause() { player?.pause() }
    func stop() { player?.pause(); player = nil }
    var currentTime: Double { player?.currentTime().seconds ?? 0 }
}

/// Plays the selected result's clip from where it matched. Never auto-plays; at most one clip at a time; stops when the
/// selection changes or the panel hides.
final class AudioPlayback: ObservableObject {
    static let shared = AudioPlayback(player: AVClipPlayer())
    private let player: ClipPlayer
    @Published private(set) var playingPath: String?
    /// Called just before a clip starts, so a video can stop first (one sound source at a time).
    var willStart: (() -> Void)?

    init(player: ClipPlayer) { self.player = player }

    func toggle(path: String, from seconds: Double) {
        if playingPath == path { player.pause(); playingPath = nil }
        else { willStart?(); player.play(path: path, from: seconds); playingPath = path }
    }

    func stop() { player.stop(); playingPath = nil }
    func isPlaying(_ path: String) -> Bool { playingPath == path }
    var time: Double { player.currentTime }
}

struct AudioPreviewView: View {
    let row: ResultRow
    @ObservedObject private var playback = AudioPlayback.shared

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary)
                Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: 90)
            Button {
                playback.toggle(path: row.path, from: row.startTime ?? 0)
            } label: {
                Label(playback.isPlaying(row.path) ? "Pause" : "Play" + (row.chips.first.map { " from \($0)" } ?? ""),
                      systemImage: playback.isPlaying(row.path) ? "pause.fill" : "play.fill")
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
