import SwiftUI

struct InputTestPlaybackView: View {
    let completion: RecordingCompletion
    @StateObject private var playback = MeetingPlaybackController()
    @State private var selectedTrack = 0

    private var tracks: [(name: String, url: URL)] {
        [("System audio", completion.systemAudioURL), ("Microphone", completion.microphoneURL)]
            .compactMap { name, url in url.map { (name: name, url: $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Input test — listen before recording").font(.headline)
            Text("Temporary audio only. Check both tracks with headphones. Starting another test or recording removes this test.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Test track", selection: $selectedTrack) {
                ForEach(tracks.indices, id: \.self) { index in
                    Text(tracks[index].name).tag(index)
                }
            }
            if tracks.indices.contains(selectedTrack) {
                MeetingPlaybackView(controller: playback, source: PlaybackSource(audioURLs: [tracks[selectedTrack].url]))
            }
        }
        .id(completion.systemAudioURL ?? completion.microphoneURL)
    }
}
