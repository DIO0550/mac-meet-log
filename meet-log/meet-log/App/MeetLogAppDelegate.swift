import AppKit

@MainActor
final class MeetLogAppDelegate: NSObject, NSApplicationDelegate {
    // The delegate lives for the entire application lifetime, including with no windows open.
    let recorderViewModel: RecorderViewModel
    private let confirmTermination: () -> Bool
    private var terminationTask: Task<Void, Never>?

    override convenience init() {
        self.init(recorderViewModel: RecorderViewModel(), confirmTermination: Self.confirmQuit)
    }

    init(recorderViewModel: RecorderViewModel, confirmTermination: @escaping () -> Bool) {
        self.recorderViewModel = recorderViewModel
        self.confirmTermination = confirmTermination
        super.init()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        guard recorderViewModel.needsTerminationConfirmation else { return .terminateNow }

        guard confirmTermination() else { return .terminateCancel }

        terminationTask = Task {
            let canQuit = await recorderViewModel.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: canQuit)
            terminationTask = nil
            guard !canQuit else { return }
            let failure = NSAlert()
            failure.messageText = "meet-log could not finish saving"
            failure.informativeText = recorderViewModel.presentedError?.message
                ?? "The recorder is still busy. Open the main window and check the recording before trying again."
            failure.alertStyle = .warning
            failure.addButton(withTitle: "OK")
            failure.runModal()
        }
        return .terminateLater
    }

    private static func confirmQuit() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Stop recording and quit meet-log?"
        alert.informativeText = "Closing the window keeps meet-log running. Quitting stops capture and waits for the recording and timestamped notes to be saved."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save and Quit")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
