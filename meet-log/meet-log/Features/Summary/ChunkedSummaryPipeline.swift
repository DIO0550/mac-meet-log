import Foundation

nonisolated struct ChunkedSummaryPipeline: Sendable {
    let promptBuilder: SummaryPromptBuilder
    let generator: SummaryGenerating

    func summarize(
        _ transcript: TranscriptResult,
        progress: SummaryProgressHandler
    ) async throws -> MeetingSummary {
        let chunker = TranscriptChunker(characterLimit: promptBuilder.characterLimit)
        let audioChunks = try chunker.split(transcript.text).map { (text: $0, screen: false) }
        let screenChunks = try chunker.split(transcript.screenText)
            .filter { !$0.isEmpty }.map { (text: $0, screen: true) }
        let chunks = audioChunks + screenChunks
        var summaries: [MeetingSummary] = []
        await progress(.chunk(completed: 0, total: chunks.count))
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            do {
                summaries.append(try await generate(chunk.text, source: transcript, integrating: false, screen: chunk.screen))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SummaryError.chunkFailed(index: index + 1, total: chunks.count, message: error.localizedDescription)
            }
            await progress(.chunk(completed: index + 1, total: chunks.count))
        }

        // Each integration round must reduce the number of summaries. This both bounds
        // model input and prevents endlessly repeating non-compressing model responses.
        var round = 1
        while true {
            try Task.checkCancellation()
            let groups = try integrationGroups(summaries)
            guard groups.count < summaries.count || summaries.count == 1 else {
                throw SummaryError.integrationFailed("中間要約を入力上限内に統合できませんでした。再試行してください。")
            }
            var merged: [MeetingSummary] = []
            await progress(.integration(round: round, completed: 0, total: groups.count))
            for (index, group) in groups.enumerated() {
                try Task.checkCancellation()
                do {
                    merged.append(try await generate(MeetingSummaryMerger.integrationText(group), source: transcript, integrating: true))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw SummaryError.integrationFailed(error.localizedDescription)
                }
                await progress(.integration(round: round, completed: index + 1, total: groups.count))
            }
            if let result = merged.first, merged.count == 1 {
                return MeetingSummaryMerger.removingDuplicates(result)
            }
            summaries = merged
            round += 1
        }
    }

    private func generate(_ text: String, source: TranscriptResult, integrating: Bool, screen: Bool = false) async throws -> MeetingSummary {
        let input = TranscriptResult(text: text, localeIdentifier: source.localeIdentifier, sourceURL: source.sourceURL)
        let base = try promptBuilder.makePrompt(for: input).get()
        var instructions = base.instructions
        if source.segments.contains(where: { $0.speaker != nil }) {
            instructions += "\n話者ラベル（自分 / 相手）を担当者推定に使い、根拠がない担当者は推測しないでください。"
        }
        if screen {
            instructions += "\n今回の入力全体は画面 OCR の補助資料です。音声の発言ではありません。全ての情報を画面由来と明記し、発言・決定として扱わないでください。"
        }
        if integrating {
            instructions += "\n入力は同じ会議の時系列の中間要約です。全てを横断して統合し、同じトピックや同一担当・期限の同じタスクを一つにまとめてください。異なる詳細・決定・担当者・期限を捨てず、原文にない事実を追加しないでください。"
        }
        let result = try await generator.generate(
            prompt: SummaryPrompt(instructions: instructions, prompt: base.prompt),
            transcript: input
        )
        try Task.checkCancellation()
        return MeetingSummaryMerger.removingDuplicates(result)
    }

    private func integrationGroups(_ summaries: [MeetingSummary]) throws -> [[MeetingSummary]] {
        var groups: [[MeetingSummary]] = []
        var current: [MeetingSummary] = []
        for summary in summaries {
            guard MeetingSummaryMerger.integrationText([summary]).count <= promptBuilder.characterLimit else {
                throw SummaryError.integrationFailed("中間要約が入力上限を超えました。再試行してください。")
            }
            let candidate = current + [summary]
            if MeetingSummaryMerger.integrationText(candidate).count > promptBuilder.characterLimit {
                groups.append(current)
                current = [summary]
                continue
            }
            current = candidate
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }
}
