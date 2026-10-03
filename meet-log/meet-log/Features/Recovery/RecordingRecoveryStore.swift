import AVFoundation
import DualTrackRecorder
import Foundation

nonisolated struct InterruptedRecording: Identifiable, Sendable {
    var id: URL { directory }
    let directory: URL
    let journal: RecordingJournal?
    let error: String?

    var recoveredDirectory: URL { directory.appendingPathComponent("recovered", isDirectory: true) }
}

nonisolated struct RecoveryReport: Codable, Equatable, Sendable {
    let sessionID: UUID
    let messages: [String]
    let noteCount: Int
}

nonisolated struct RecoveryMediaPart: Sendable {
    let url: URL
    let start: TimeInterval
    let duration: TimeInterval
}

nonisolated struct RecoveryInspection: Sendable {
    let system: [RecoveryMediaPart]
    let microphone: [RecoveryMediaPart]
    let screen: [RecoveryMediaPart]
    let notes: [RecordingNote]
    let report: RecoveryReport
}

actor RecordingRecoveryStore {
    nonisolated static let reportFileName = "recovery-report.json"
    private var recovering: Set<URL> = []

    /// Corrupt checkpoints stay visible, and legacy recordings without a journal are untouched.
    nonisolated static func interrupted(in root: URL) throws -> [InterruptedRecording] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { directory in
                guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(RecordingJournal.fileName).path),
                      !FileManager.default.fileExists(atPath: directory.appendingPathComponent(RecordingJournal.completionFileName).path) else {
                    return nil
                }
                do {
                    let journal = try RecordingJournal.load(in: directory)
                    let recovered = directory.appendingPathComponent("recovered")
                    if let report = try? loadReport(in: recovered), report.sessionID == journal.id { return nil }
                    return InterruptedRecording(directory: directory, journal: journal, error: nil)
                } catch {
                    return InterruptedRecording(directory: directory, journal: nil,
                                                error: "セッション情報を読み出せません。原本は保持されています。\n\(error.localizedDescription)")
                }
            }
    }

    nonisolated static func loadReport(in directory: URL) throws -> RecoveryReport {
        try JSONDecoder().decode(RecoveryReport.self, from: Data(contentsOf: directory.appendingPathComponent(reportFileName)))
    }

    func inspect(_ session: InterruptedRecording) async throws -> RecoveryInspection {
        guard let journal = session.journal else { throw CocoaError(.fileReadCorruptFile) }
        var messages = ["最終チェックポイント: \(journal.elapsed.formatted(.number.precision(.fractionLength(1)))) 秒（\(journal.phase.rawValue)）。これ以後の経過時間は不明です。"]
        let system = await audioParts(session, kind: "system", enabled: journal.systemAudioEnabled, messages: &messages)
        let microphone = await audioParts(session, kind: "microphone", enabled: journal.microphoneEnabled, messages: &messages)
        var screen: [RecoveryMediaPart] = []
        if journal.screenCaptureEnabled {
            let url = session.directory.appendingPathComponent("\(journal.stem)_screen.mp4")
            if let duration = await readableDuration(url, type: .video) {
                screen = [RecoveryMediaPart(url: url, start: 0, duration: duration)]
                messages.append("画面: 0–\(seconds(duration)) 秒を読み出せます。未確定フラグメント・末尾は失われた可能性があります。")
            } else {
                messages.append("画面: 欠損または読み出し不能。ファイルは削除しません。")
            }
        }
        var notes: [RecordingNote] = []
        do {
            notes = try RecordingNoteStore().load(from: session.directory.appendingPathComponent("\(journal.stem)_notes.json"))
        } catch {
            messages.append("メモ: 保存ファイルが破損しているため復旧できません。原本は保持します。")
        }
        messages.append("音声バックアップは約5秒ごと、画面は10秒ごとの確定保存です。強制終了直前の未確定区間・保存に失敗したメモは救出できない場合があります。表示範囲内でもキャプチャ時の無音・欠落は判別できません。")
        return RecoveryInspection(system: system, microphone: microphone, screen: screen, notes: notes,
                                  report: RecoveryReport(sessionID: journal.id, messages: messages, noteCount: notes.count))
    }

    /// Publish one complete directory by rename. Repeated recovery returns the existing result;
    /// neither original files nor an already edited recovered recording are ever overwritten.
    func recover(_ session: InterruptedRecording) async throws -> RecoveryReport {
        guard let journal = session.journal else { throw CocoaError(.fileReadCorruptFile) }
        guard recovering.insert(session.directory).inserted else { throw CocoaError(.fileWriteFileExists) }
        defer { recovering.remove(session.directory) }
        let destination = session.recoveredDirectory
        if FileManager.default.fileExists(atPath: destination.path) {
            let report = try Self.loadReport(in: destination)
            guard report.sessionID == journal.id else { throw CocoaError(.fileReadCorruptFile) }
            return report
        }
        let inspection = try await inspect(session)
        let staging = session.directory.appendingPathComponent(".recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        // Staging contains only derived files. Originals and backup segments are never removed.
        defer { try? FileManager.default.removeItem(at: staging) }
        var messages = inspection.report.messages
        let system = await restoreAudio(inspection.system, session: session, kind: "system", enabled: journal.systemAudioEnabled, in: staging, messages: &messages)
        let microphone = await restoreAudio(inspection.microphone, session: session, kind: "microphone", enabled: journal.microphoneEnabled, in: staging, messages: &messages)
        let screen = await restore(inspection.screen, type: .video, to: staging.appendingPathComponent("\(journal.stem)_screen.mp4"), messages: &messages)
        guard system != nil || microphone != nil || screen != nil || !inspection.notes.isEmpty else {
            throw RecorderError.outputFailed("復旧可能な素材・保存済みメモがありません。原本は保持されています。\n" + messages.joined(separator: "\n"))
        }
        try RecordingNoteStore().save(inspection.notes, to: staging.appendingPathComponent("\(journal.stem)_notes.json"))
        if system != nil || microphone != nil {
            do {
                _ = try await RecordingMixdownService().export(systemAudioURL: system, microphoneURL: microphone,
                    destinationURL: staging.appendingPathComponent("\(journal.stem)_mix.m4a"))
            } catch {
                messages.append("再mixdownに失敗しました。復旧トラックは保存済みです。Libraryで再実行できます。\n\(error.localizedDescription)")
            }
        }
        let report = RecoveryReport(sessionID: journal.id, messages: messages, noteCount: inspection.notes.count)
        try JSONEncoder().encode(report).write(to: staging.appendingPathComponent(Self.reportFileName), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: destination)
        return report
    }

    private func restoreAudio(_ parts: [RecoveryMediaPart], session: InterruptedRecording, kind: String,
                              enabled: Bool, in directory: URL, messages: inout [String]) async -> URL? {
        guard let journal = session.journal, enabled else { return nil }
        let output = directory.appendingPathComponent("\(journal.stem)_\(kind).m4a")
        if let restored = await restore(parts, type: .audio, to: output, messages: &messages) { return restored }
        guard parts.contains(where: { $0.url.deletingLastPathComponent() == session.directory }) else { return nil }
        let backups = await audioParts(session, kind: kind, enabled: enabled, messages: &messages, preferOriginal: false)
        return await restore(backups, type: .audio, to: output, messages: &messages)
    }

    private func audioParts(_ session: InterruptedRecording, kind: String, enabled: Bool,
                            messages: inout [String], preferOriginal: Bool = true) async -> [RecoveryMediaPart] {
        guard enabled, let journal = session.journal else { return [] }
        let original = session.directory.appendingPathComponent("\(journal.stem)_\(kind).m4a")
        if preferOriginal, let duration = await readableDuration(original, type: .audio) {
            messages.append("\(kind): 元トラックの 0–\(seconds(duration)) 秒を読み出せます。")
            return [RecoveryMediaPart(url: original, start: 0, duration: duration)]
        }
        let directory = original.deletingPathExtension().appendingPathExtension("segments")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var parts: [RecoveryMediaPart] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let range = Self.segmentRange(url), let duration = await readableDuration(url, type: .audio) else { continue }
            parts.append(RecoveryMediaPart(url: url, start: range.lowerBound, duration: min(duration, range.upperBound - range.lowerBound)))
        }
        guard !parts.isEmpty else {
            messages.append("\(kind): 読み出せる確定済み音声なし。未確定ファイルを含め原本は保持します。")
            return []
        }
        var end: TimeInterval = 0
        for part in parts {
            if part.start - end > 0.01 { messages.append("\(kind): \(seconds(end))–\(seconds(part.start)) 秒が欠損しています。") }
            end = max(end, part.start + part.duration)
        }
        messages.append("\(kind): 確定済み音声 \(parts.count) 区間、最終 \(seconds(end)) 秒。以後の未確定音声は復旧対象外です。")
        return parts
    }

    nonisolated static func segmentRange(_ url: URL) -> Range<TimeInterval>? {
        guard url.pathExtension == "m4a" else { return nil }
        let pieces = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard pieces.count == 2, let start = Double(pieces[0]), let end = Double(pieces[1]),
              start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        return (start / 1_000_000)..<(end / 1_000_000)
    }

    private func readableDuration(_ url: URL, type: AVMediaType) async -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isReadable), let track = try await asset.loadTracks(withMediaType: type).first else { return nil }
            let range = try await track.load(.timeRange)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            guard end.isFinite, end > 0 else { return nil }
            return end
        } catch { return nil }
    }

    private func restore(_ parts: [RecoveryMediaPart], type: AVMediaType, to url: URL,
                         messages: inout [String]) async -> URL? {
        guard !parts.isEmpty else { return nil }
        do {
            let composition = AVMutableComposition()
            guard let output = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for part in parts {
                let asset = AVURLAsset(url: part.url)
                guard let track = try await asset.loadTracks(withMediaType: type).first else { throw CocoaError(.fileReadCorruptFile) }
                let range = try await track.load(.timeRange)
                let end = CMTimeMinimum(CMTimeRangeGetEnd(range), CMTime(seconds: part.duration, preferredTimescale: 1_000_000))
                let selected = CMTimeRange(start: range.start, end: end)
                let position = CMTimeAdd(CMTime(seconds: part.start, preferredTimescale: 1_000_000), range.start)
                try output.insertTimeRange(selected, of: track, at: position)
                if type == .video { output.preferredTransform = try await track.load(.preferredTransform) }
            }
            let preset = type == .audio ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
            guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else { throw CocoaError(.fileWriteUnknown) }
            exporter.outputURL = url
            exporter.outputFileType = type == .audio ? .m4a : .mp4
            await exporter.export()
            guard exporter.status == .completed, await readableDuration(url, type: type) != nil else {
                throw exporter.error ?? CocoaError(.fileWriteUnknown)
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url) // Only this attempt's derived output.
            messages.append("\(url.lastPathComponent): 書き出しに失敗しました。原本は保持します。\n\(error.localizedDescription)")
            return nil
        }
    }

    private func seconds(_ value: TimeInterval) -> String { String(format: "%.1f", value) }
}
