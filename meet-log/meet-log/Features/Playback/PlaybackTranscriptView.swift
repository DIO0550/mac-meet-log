import SwiftUI

struct PlaybackTranscriptView: View {
    let transcript: TranscriptResult
    let seek: (Double) -> Void

    var body: some View {
        if transcript.segments.isEmpty {
            Text(transcript.text).textSelection(.enabled)
            Text("この文字起こしには時刻情報がありません。シークバーを利用してください。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { entry in
                    let segment = entry.element
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        PlaybackTimestampButton(title: segment.timeRangeText, seconds: segment.timestamp, seek: seek)
                            .font(.caption)
                        if let speaker = segment.speaker {
                            Text(speaker.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(speaker == .me ? Color.green : Color.blue)
                        }
                        Text(segment.text)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
