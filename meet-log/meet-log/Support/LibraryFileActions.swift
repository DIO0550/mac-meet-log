import AppKit
import AVFoundation
import Foundation

enum LibraryFinder {
    static func reveal(fileURL: URL) {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return
        }

        let folderURL = fileURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: folderURL.path) {
            NSWorkspace.shared.open(folderURL)
            return
        }

        NSWorkspace.shared.open(folderURL.deletingLastPathComponent())
    }
}

@MainActor
final class MixdownPlaybackController: NSObject, AVAudioPlayerDelegate {
    enum State: Equatable {
        case stopped
        case playing(URL)
        case failed(String)
    }

    private(set) var state: State = .stopped
    private var player: AVAudioPlayer?
    private let onStateChange: (State) -> Void

    init(onStateChange: @escaping (State) -> Void) {
        self.onStateChange = onStateChange
    }

    func toggle(url: URL) {
        if case let .playing(playingURL) = state, playingURL == url {
            stop()
            return
        }

        play(url: url)
    }

    func stop() {
        player?.stop()
        player = nil
        update(state: .stopped)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        update(state: .stopped)
    }

    private func play(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            update(state: .failed("The mixdown file is no longer available."))
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            update(state: .playing(url))
        } catch {
            update(state: .failed("The mixdown could not be played."))
        }
    }

    private func update(state: State) {
        self.state = state
        onStateChange(state)
    }
}
