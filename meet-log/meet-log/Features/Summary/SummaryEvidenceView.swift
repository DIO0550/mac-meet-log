import SwiftUI

struct SummaryEvidenceView: View {
    let ids: [String]?
    let fingerprint: String?
    let transcript: TranscriptResult?
    let seek: (Double) -> Void

    var body: some View {
        let catalog = transcript.map(SummaryEvidenceCatalog.init)
        let evidence = catalog?.resolve(ids, fingerprint: fingerprint) ?? []
        let requested = Set(ids ?? [])
        let missing = requested.subtracting(evidence.map(\.id))

        if evidence.isEmpty {
            Label("根拠: 未確認", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            if evidence.contains(where: { $0.source == .audio }) {
                Label("根拠: 音声", systemImage: "waveform").font(.caption)
            }
            if evidence.contains(where: { $0.source == .screen }) {
                Label("根拠: 画面 OCR・補助情報（合意は未確認）", systemImage: "text.viewfinder")
                    .font(.caption)
            }
            DisclosureGroup("根拠の原文（\(evidence.count)件）") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(evidence) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label(entry.source.label, systemImage: entry.source == .audio ? "waveform" : "text.viewfinder")
                                PlaybackTimestampButton(title: entry.timeRangeText, seconds: entry.timestamp, seek: seek)
                            }
                            .font(.caption)
                            Text(entry.text)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                    if !missing.isEmpty {
                        Text("一部の根拠は未確認です。入力の更新や参照先の欠損により確認できません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
        }
    }
}
