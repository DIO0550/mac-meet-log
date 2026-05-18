import DualTrackRecorder
import SwiftUI

struct RecordingCompleteView: View {
    let completion: RecordingCompletion
    let revealAction: () -> Void
    let dismissAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording Saved")
                        .font(.headline)

                    Text(completion.duration.recorderDisplayString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(action: dismissAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            Text(completion.displayFileName)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: revealAction) {
                Label("Show in Finder", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.green.opacity(0.28), lineWidth: 1)
        )
    }
}
