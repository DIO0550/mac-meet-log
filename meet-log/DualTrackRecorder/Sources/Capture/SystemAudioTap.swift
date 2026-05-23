import AVFoundation
import CoreAudio
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
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var bufferHandler: AudioBufferHandler?
    private let ioQueue = DispatchQueue(label: "DualTrackRecorder.system-audio-tap.io")

    func start(bufferHandler: @escaping AudioBufferHandler) async throws {
        guard #available(macOS 14.2, *) else {
            throw RecorderError.captureFailed("System audio capture requires macOS 14.2 or later.")
        }

        self.bufferHandler = bufferHandler

        do {
            try createProcessTap()
            let tapUID = try readTapUID()
            format = try readTapFormat()
            try createAggregateDevice(tapUID: tapUID)
            try createIOProc()
            try startAggregateDevice()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }

        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        format = nil
        bufferHandler = nil
    }

    @available(macOS 14.2, *)
    private func createProcessTap() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "meet-log System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else {
            throw RecorderError.captureFailed(
                "System audio permission was denied or the process tap could not be created. \(Self.describe(status: status))"
            )
        }

        tapID = newTapID
    }

    private func readTapUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &uid)

        guard status == noErr, let uid else {
            throw RecorderError.captureFailed("Could not read system audio tap UID. \(Self.describe(status: status))")
        }

        return uid.takeRetainedValue() as String
    }

    private func readTapFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamDescription = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &streamDescription)

        guard status == noErr else {
            throw RecorderError.captureFailed("Could not read system audio tap format. \(Self.describe(status: status))")
        }

        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw RecorderError.captureFailed("System audio tap returned an unsupported audio format.")
        }

        return format
    }

    private func createAggregateDevice(tapUID: String) throws {
        let aggregateUID = "meet-log.system-audio.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "meet-log System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID
                ]
            ]
        ]

        var newDeviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDeviceID)
        guard status == noErr else {
            throw RecorderError.captureFailed(
                "Could not create system audio aggregate device. \(Self.describe(status: status))"
            )
        }

        aggregateDeviceID = newDeviceID
        try setAggregateTapList(tapUID: tapUID)
    }

    private func setAggregateTapList(tapUID: String) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let tapList = [tapUID as CFString] as CFArray
        let dataSize = UInt32(MemoryLayout<CFArray>.size)
        let status = withUnsafePointer(to: tapList) { tapListPointer in
            AudioObjectSetPropertyData(aggregateDeviceID, &address, 0, nil, dataSize, tapListPointer)
        }

        guard status == noErr else {
            throw RecorderError.captureFailed(
                "Could not attach the system audio tap to the aggregate device. \(Self.describe(status: status))"
            )
        }
    }

    private func createIOProc() throws {
        var newIOProcID: AudioDeviceIOProcID?
        let block: AudioDeviceIOBlock = { [weak self] _, inputData, inputTime, _, _ in
            self?.handle(inputData: inputData, inputTime: inputTime)
        }
        let status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, ioQueue, block)

        guard status == noErr, let newIOProcID else {
            throw RecorderError.captureFailed("Could not create system audio IO callback. \(Self.describe(status: status))")
        }

        ioProcID = newIOProcID
    }

    private func startAggregateDevice() throws {
        let status = AudioDeviceStart(aggregateDeviceID, ioProcID)

        guard status == noErr else {
            throw RecorderError.captureFailed("Could not start system audio capture. \(Self.describe(status: status))")
        }
    }

    private func handle(inputData: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>) {
        guard let format, let bufferHandler else {
            return
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: inputData,
            deallocator: nil
        ) else {
            return
        }

        let bytesPerFrame = max(Int(format.streamDescription.pointee.mBytesPerFrame), 1)
        let frameLength = inputData.pointee.mBuffers.mDataByteSize / UInt32(bytesPerFrame)
        buffer.frameLength = min(frameLength, buffer.frameCapacity)

        bufferHandler(buffer, AVAudioTime(hostTime: inputTime.pointee.mHostTime))
    }

    private static func describe(status: OSStatus) -> String {
        let unsignedStatus = UInt32(bitPattern: status)
        let bytes = [
            UInt8((unsignedStatus >> 24) & 0xff),
            UInt8((unsignedStatus >> 16) & 0xff),
            UInt8((unsignedStatus >> 8) & 0xff),
            UInt8(unsignedStatus & 0xff)
        ]

        if bytes.allSatisfy({ 32...126 ~= $0 }),
           let fourCharacterCode = String(bytes: bytes, encoding: .ascii) {
            return "OSStatus \(status) ('\(fourCharacterCode)')."
        }

        return "OSStatus \(status)."
    }
}
