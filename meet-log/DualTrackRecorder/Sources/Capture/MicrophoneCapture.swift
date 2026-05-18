import AVFoundation
import Foundation

final class MicrophoneCapture: AudioCapture {
    private let engine = AVAudioEngine()
    private let bufferHandler: AudioBufferHandler
    private var isRunning = false

    init(bufferHandler: @escaping AudioBufferHandler) {
        self.bufferHandler = bufferHandler
    }

    func start() async throws {
        guard !isRunning else {
            return
        }

        try await verifyMicrophonePermission()

        do {
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [bufferHandler] buffer, time in
                bufferHandler(buffer, time)
            }

            engine.prepare()
            try engine.start()
            isRunning = true
        } catch let error as RecorderError {
            throw error
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            throw RecorderError.captureFailed("Could not start microphone capture: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else {
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func verifyMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                throw RecorderError.permissionDenied("Microphone permission was denied.")
            }
        case .denied, .restricted:
            throw RecorderError.permissionDenied("Microphone permission was denied.")
        @unknown default:
            throw RecorderError.permissionDenied("Microphone permission is unavailable.")
        }
    }
}
