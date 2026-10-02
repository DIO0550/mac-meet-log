import SwiftUI

struct ScreenTranscriptView: View {
    let transcript: TranscriptResult?
    let warning: String?

    var body: some View {
        if let warning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
        if let transcript, let report = transcript.screenOCRReport {
            VStack(alignment: .leading, spacing: 12) {
                Label("画面テキスト（OCR）", systemImage: "text.viewfinder")
                    .font(.headline)
                Text("画面に表示された補助情報です。発言とは区別して確認してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if transcript.screenSegments.isEmpty {
                    Text("画面内に認識できる文字はありませんでした。")
                }
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(transcript.screenSegments.enumerated()), id: \.offset) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            Text(entry.element.timeRangeText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                            Text(entry.element.text)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                }
                Text(String(format: "処理 %.1f 秒 · OCR %d / %d フレーム", report.elapsedSeconds, report.recognizedFrames, report.sampledFrames))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
