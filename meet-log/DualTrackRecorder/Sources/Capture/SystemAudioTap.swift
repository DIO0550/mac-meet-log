import Foundation

final class SystemAudioTap: AudioCapture {
    private let backend: any ProcessTapBackend
    private let bufferHandler: AudioBufferHandler
    private var isRunning = false

    init(
        bufferHandler: @escaping AudioBufferHandler,
        backend: any ProcessTapBackend = DefaultProcessTapBackend()
    ) {
        self.bufferHandler = bufferHandler
        self.backend = backend
    }

    func start() async throws {
        guard !isRunning else {
            return
        }

        do {
            try await backend.start(bufferHandler: bufferHandler)
            isRunning = true
        } catch let error as RecorderError {
            throw error
        } catch {
            throw RecorderError.captureFailed("Could not start system audio capture: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else {
            return
        }

        backend.stop()
        isRunning = false
    }
}

protocol ProcessTapBackend {
    func start(bufferHandler: @escaping AudioBufferHandler) async throws
    func stop()
}

final class DefaultProcessTapBackend: ProcessTapBackend {
    func start(bufferHandler _: @escaping AudioBufferHandler) async throws {
        guard #available(macOS 14.2, *) else {
            throw RecorderError.captureFailed("System audio capture requires macOS 14.2 or later.")
        }

        throw RecorderError.captureFailed("System audio Process Tap is isolated but not available in this build.")
    }

    func stop() {}
}
