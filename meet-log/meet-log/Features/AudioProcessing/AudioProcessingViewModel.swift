import AppKit
import Combine
import Foundation

@MainActor
final class AudioProcessingViewModel: ObservableObject {
    @Published private(set) var state: AudioProcessingJobState = .idle
    @Published var isImporterPresented = false

    private let job: AudioProcessingJob
    private let locale: Locale
    private var processingTask: Task<Void, Never>?
    private var lastSelectedURL: URL?

    init(
        job: AudioProcessingJob = AudioProcessingJob(),
        locale: Locale = Locale(identifier: "ja-JP")
    ) {
        self.job = job
        self.locale = locale
    }

    deinit {
        processingTask?.cancel()
    }

    var isProcessing: Bool {
        switch state {
        case .loading, .transcribing, .summarizing:
            return true
        case .idle, .completed, .failed, .cancelled:
            return false
        }
    }

    var canRetry: Bool {
        lastSelectedURL != nil && !isProcessing
    }

    var transcriptText: String? {
        if let transcript = state.transcript, !transcript.text.isEmpty {
            return transcript.text
        }

        if case let .transcribing(_, partialTranscript) = state {
            return partialTranscript
        }

        return nil
    }

    var summaryText: String? {
        guard case let .completed(_, _, result) = state,
              case let .summarized(summary) = result else {
            return nil
        }

        return formattedSummary(summary)
    }

    var selectedFileName: String? {
        state.importedItem?.fileName ?? lastSelectedURL?.lastPathComponent
    }

    func presentImporter() {
        isImporterPresented = true
    }

    func handleImporterResult(_ result: Result<URL, Error>) {
        isImporterPresented = false

        switch result {
        case let .success(url):
            process(audioURL: url)
        case let .failure(error):
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                if case .idle = state {
                    return
                }
                state = .idle
                return
            }

            state = .failed(nil, .unexpected(error.localizedDescription), transcript: nil)
        }
    }

    func process(audioURL: URL) {
        processingTask?.cancel()
        lastSelectedURL = audioURL
        state = .loading

        processingTask = Task {
            for await nextState in job.run(audioURL: audioURL, locale: locale) {
                state = nextState
            }
            processingTask = nil
        }
    }

    func cancel() {
        let item = state.importedItem
        processingTask?.cancel()
        processingTask = nil
        state = .cancelled(item)
    }

    func retry() {
        guard let lastSelectedURL else {
            return
        }

        process(audioURL: lastSelectedURL)
    }

    func clear() {
        processingTask?.cancel()
        processingTask = nil
        state = .idle
    }

    func copyTranscript() {
        guard let transcriptText else {
            return
        }

        copy(transcriptText)
    }

    func copySummary() {
        guard let summaryText else {
            return
        }

        copy(summaryText)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func formattedSummary(_ summary: MeetingSummary) -> String {
        var sections = [summary.summary]

        if !summary.topics.isEmpty {
            sections.append(
                """
                Topics
                \(summary.topics.map { topic in
                    if let detail = topic.detail, !detail.isEmpty {
                        return "- \(topic.title): \(detail)"
                    }

                    return "- \(topic.title)"
                }.joined(separator: "\n"))
                """
            )
        }

        if !summary.actionItems.isEmpty {
            sections.append(
                """
                Action Items
                \(summary.actionItems.map { item in
                    let owner = item.owner.map { " [\($0)]" } ?? ""
                    let due = item.dueDateText.map { " (\($0))" } ?? ""
                    return "- \(item.title)\(owner)\(due)"
                }.joined(separator: "\n"))
                """
            )
        }

        return sections.joined(separator: "\n\n")
    }
}
