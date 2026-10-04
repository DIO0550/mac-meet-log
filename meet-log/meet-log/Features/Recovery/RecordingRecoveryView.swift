import SwiftUI
import DualTrackRecorder

struct RecordingRecoveryView: View {
    let sessions: [InterruptedRecording]
    let openLibrary: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("未完了の録音を復旧").font(.title2.bold())
            Text("原本を保持したまま、読み出せる素材と保存済みメモをLibraryへ登録します。後で復旧する場合はこの画面を閉じてください。")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(sessions) { session in
                        RecoverySessionRow(session: session)
                        Divider()
                    }
                }
            }
            HStack {
                Button("閉じる") { dismiss() }
                Spacer()
                Button("Libraryを開く") { dismiss(); openLibrary() }
            }
        }
        .padding(24)
        .frame(width: 660, height: 560)
    }
}

private struct RecoverySessionRow: View {
    let session: InterruptedRecording
    @State private var inspection: RecoveryInspection?
    @State private var report: RecoveryReport?
    @State private var error: String?
    @State private var busy = false
    private static let store = RecordingRecoveryStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.journal?.stem ?? session.directory.lastPathComponent).font(.headline)
            if let error = error ?? session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let details = report ?? inspection?.report {
                Text("保存済みメモ: \(details.noteCount) 件")
                ForEach(Array(details.messages.enumerated()), id: \.offset) { _, message in
                    Text(message).font(.callout).textSelection(.enabled)
                }
            }
            if busy { ProgressView("素材を確認・復旧しています…") }
            HStack {
                Button("原本をFinderで表示") { FinderReveal.reveal(fileURL: session.directory) }
                if report != nil {
                    Text("Libraryに登録済み").foregroundStyle(.green)
                } else if session.journal != nil {
                    Button("復旧してLibraryへ登録") {
                        busy = true
                        error = nil
                        Task {
                            defer { busy = false }
                            do { report = try await Self.store.recover(session) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(busy || inspection == nil)
                }
            }
        }
        .task {
            guard session.journal != nil else { return }
            busy = true
            defer { busy = false }
            do { inspection = try await Self.store.inspect(session) }
            catch { self.error = error.localizedDescription }
        }
    }
}
