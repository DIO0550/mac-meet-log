import AVFoundation
import AudioToolbox
import Foundation

final class MicrophoneCapture: AudioCapture {
    private let engine = AVAudioEngine()
    private let deviceSelection: MicrophoneInputDeviceSelection
    private let deviceProvider: any MicrophoneDeviceProviding
    private let bufferHandler: AudioBufferHandler
    private var isRunning = false

    init(
        deviceSelection: MicrophoneInputDeviceSelection = .systemDefault,
        deviceProvider: any MicrophoneDeviceProviding = CoreAudioMicrophoneDeviceProvider(),
        bufferHandler: @escaping AudioBufferHandler
    ) {
        self.deviceSelection = deviceSelection
        self.deviceProvider = deviceProvider
        self.bufferHandler = bufferHandler
    }

    func start() async throws {
        guard !isRunning else {
            return
        }

        try await verifyMicrophonePermission()

        do {
            try configureSelectedInputDevice()

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

    private func configureSelectedInputDevice() throws {
        guard let deviceID = deviceSelection.deviceID else {
            return
        }

        guard let audioDeviceID = AudioDeviceID(deviceID),
              try deviceProvider.containsDevice(id: deviceID) else {
            throw RecorderError.audioInputDeviceUnavailable("Audio input device is unavailable: \(deviceID)")
        }

        guard let audioUnit = engine.inputNode.audioUnit else {
            throw RecorderError.captureFailed("Could not access microphone input audio unit.")
        }

        var selectedDeviceID = audioDeviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw RecorderError.audioInputDeviceUnavailable("Audio input device is unavailable: \(deviceID)")
        }
    }
}
