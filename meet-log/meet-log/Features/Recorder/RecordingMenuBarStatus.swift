import DualTrackRecorder

struct RecordingMenuBarStatus: Equatable {
    let text: String
    let systemImage: String

    init(state: RecorderState, isStarting: Bool = false, isStopping: Bool = false, hasError: Bool = false) {
        let status: String
        let symbol: String
        switch state {
        case .idle, .complete:
            status = "Stopped"
            symbol = "stop.circle"
        case .preparing:
            status = "Preparing"
            symbol = "record.circle"
        case .recording:
            status = "Recording"
            symbol = "record.circle.fill"
        case .paused:
            status = "Paused"
            symbol = "pause.circle.fill"
        case .finalizing:
            status = "Saving"
            symbol = "arrow.down.circle"
        case .failed:
            text = "Error"
            systemImage = "exclamationmark.triangle.fill"
            return
        }
        let operation = isStopping ? "Saving" : (isStarting ? "Preparing" : status)
        text = hasError ? "\(operation) · Error" : operation
        systemImage = hasError ? "exclamationmark.triangle.fill" : symbol
    }
}
