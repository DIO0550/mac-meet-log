import CryptoKit
import Foundation

nonisolated struct SummaryEvidence: Equatable, Identifiable, Sendable {
    enum Source: String, Sendable {
        case audio
        case screen

        var label: String {
            switch self {
            case .audio:
                return "音声"
            case .screen:
                return "画面 OCR・補助情報（合意は未確認）"
            }
        }
    }

    let id: String
    let source: Source
    let text: String
    let timestamp: TimeInterval
    let duration: TimeInterval
    let speaker: TranscriptSpeaker?

    var timeRangeText: String {
        TranscriptSegment(text: text, timestamp: timestamp, duration: duration).timeRangeText
    }

    var promptLabel: String {
        let speakerLabel = speaker.map { "\($0.displayName): " } ?? ""
        return "[\(id) \(source.label) \(timeRangeText)] \(speakerLabel)"
    }
}

/// Content identities prevent an old index from being rebound after editing or reordering.
nonisolated struct SummaryEvidenceCatalog: Sendable {
    let entries: [SummaryEvidence]
    let fingerprint: String
    let audioInput: [SummaryEvidenceInput]
    let screenInput: [SummaryEvidenceInput]

    init(_ transcript: TranscriptResult) {
        let audioInput = transcript.segments.map { segment in
            let evidence = Self.entry(source: .audio, text: segment.text, timestamp: segment.timestamp,
                                      duration: segment.duration, speaker: segment.speaker, url: transcript.sourceURL)
            return SummaryEvidenceInput(text: segment.text, screen: false, evidence: evidence)
        }
        let screenInput = transcript.screenSegments.map { segment in
            let evidence = Self.entry(source: .screen, text: segment.text, timestamp: segment.timestamp,
                                      duration: segment.duration, speaker: nil, url: transcript.sourceURL)
            return SummaryEvidenceInput(text: segment.text, screen: true, evidence: evidence)
        }
        self.audioInput = audioInput
        self.screenInput = screenInput
        let audio = audioInput.compactMap(\.evidence)
        let screen = screenInput.compactMap(\.evidence)
        var seen = Set<String>()
        let entries = (audio + screen).filter { seen.insert($0.id).inserted }
        self.entries = entries
        fingerprint = Self.hash([transcript.sourceURL.absoluteString, transcript.summaryInputText]
            + entries.map(\.id))
    }

    var ids: Set<String> { Set(entries.map(\.id)) }

    func resolve(_ ids: [String]?, fingerprint expected: String?) -> [SummaryEvidence] {
        guard expected == fingerprint else {
            return []
        }
        let wanted = Set(ids ?? [])
        return entries.filter { wanted.contains($0.id) }
    }

    static func modelInput(_ transcript: TranscriptResult) -> String {
        let catalog = Self(transcript)
        let audio = catalog.audioInput.isEmpty ? transcript.text : catalog.audioInput.map(\.modelText).joined(separator: "\n")
        guard !transcript.screenSegments.isEmpty else {
            return audio
        }
        let screen = catalog.screenInput.map(\.modelText).joined(separator: "\n")
        return "[音声]\n\(audio)\n\n[画面 OCR・補助情報]\n\(screen)"
    }

    private static func entry(
        source: SummaryEvidence.Source, text: String, timestamp: TimeInterval,
        duration: TimeInterval, speaker: TranscriptSpeaker?, url: URL
    ) -> SummaryEvidence? {
        guard timestamp.isFinite, duration.isFinite, timestamp >= 0, duration >= 0,
              (timestamp + duration).isFinite, timestamp + duration < Double(Int.max),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let identity = hash([url.absoluteString, source.rawValue, text,
                             String(timestamp), String(duration), speaker?.rawValue ?? ""])
        return SummaryEvidence(id: "\(source.rawValue)-\(identity.prefix(16))", source: source,
                               text: text, timestamp: timestamp, duration: duration, speaker: speaker)
    }

    private static func hash(_ fields: [String]) -> String {
        // Length framing avoids ambiguous identities when text contains separators.
        let value = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct SummaryEvidenceInput: Sendable {
    let text: String
    let screen: Bool
    let evidence: SummaryEvidence?

    var label: String {
        guard let evidence else {
            return screen ? "[画面 OCR・補助情報・時刻未確認] " : "[音声・時刻未確認] "
        }
        return evidence.promptLabel
    }

    var modelText: String { label + text }
}

extension MeetingSummary {
    var hasEvidence: Bool {
        if !(evidenceIDs ?? []).isEmpty {
            return true
        }
        if topics.contains(where: { !($0.evidenceIDs ?? []).isEmpty }) {
            return true
        }
        return actionItems.contains { !($0.evidenceIDs ?? []).isEmpty }
    }

    func restrictingEvidence(to allowed: Set<String>, fingerprint: String? = nil) -> MeetingSummary {
        func checked(_ ids: [String]?) -> [String]? {
            guard let ids else {
                return nil
            }
            var seen = Set<String>()
            return ids.map { allowed.contains($0) ? $0 : "unconfirmed" }
                .filter { seen.insert($0).inserted }
        }
        return MeetingSummary(
            summary: summary,
            topics: topics.map {
                MeetingTopic(id: $0.id, title: $0.title, detail: $0.detail, evidenceIDs: checked($0.evidenceIDs))
            },
            actionItems: actionItems.map {
                MeetingActionItem(id: $0.id, title: $0.title, owner: $0.owner,
                                  dueDateText: $0.dueDateText, evidenceIDs: checked($0.evidenceIDs))
            },
            transcriptSourceURL: transcriptSourceURL, createdAt: createdAt,
            templateID: templateID, templateName: templateName, inputFingerprint: inputFingerprint,
            editedAt: editedAt, evidenceIDs: checked(evidenceIDs),
            evidenceInputFingerprint: hasEvidence ? fingerprint : nil
        )
    }
}
