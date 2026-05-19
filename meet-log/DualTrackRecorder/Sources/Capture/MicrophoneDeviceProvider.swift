import AudioToolbox
import CoreAudio
import Foundation

protocol MicrophoneDeviceProviding: Sendable {
    func devices() throws -> [AudioInputDevice]
    func deviceChanges() -> AsyncStream<[AudioInputDevice]>
}

extension MicrophoneDeviceProviding {
    func containsDevice(id: AudioInputDevice.ID) throws -> Bool {
        try devices().contains { $0.id == id }
    }
}

final class CoreAudioMicrophoneDeviceProvider: MicrophoneDeviceProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "DualTrackRecorder.microphone-device-provider")

    func devices() throws -> [AudioInputDevice] {
        let defaultInputID = try defaultInputDeviceID()

        return try audioDeviceIDs()
            .filter(isInputDevice)
            .compactMap { deviceID in
                guard let name = try deviceName(for: deviceID) else {
                    return nil
                }

                return AudioInputDevice(
                    id: String(deviceID),
                    name: name,
                    isDefault: deviceID == defaultInputID
                )
            }
            .sorted { first, second in
                if first.isDefault != second.isDefault {
                    return first.isDefault
                }

                return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            }
    }

    func deviceChanges() -> AsyncStream<[AudioInputDevice]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let addresses = [
                Self.propertyAddress(selector: kAudioHardwarePropertyDevices),
                Self.propertyAddress(selector: kAudioHardwarePropertyDefaultInputDevice)
            ]
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else {
                    return
                }

                do {
                    continuation.yield(try self.devices())
                } catch {
                    continuation.finish()
                }
            }

            for address in addresses {
                var mutableAddress = address
                AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &mutableAddress,
                    queue,
                    block
                )
            }

            do {
                continuation.yield(try devices())
            } catch {
                continuation.finish()
            }

            continuation.onTermination = { _ in
                for address in addresses {
                    var mutableAddress = address
                    AudioObjectRemovePropertyListenerBlock(
                        AudioObjectID(kAudioObjectSystemObject),
                        &mutableAddress,
                        self.queue,
                        block
                    )
                }
            }
        }
    }

    private func audioDeviceIDs() throws -> [AudioDeviceID] {
        var address = Self.propertyAddress(selector: kAudioHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else {
            throw RecorderError.captureFailed("Could not read audio input devices.")
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else {
            throw RecorderError.captureFailed("Could not read audio input devices.")
        }

        return deviceIDs
    }

    private func defaultInputDeviceID() throws -> AudioDeviceID? {
        var address = Self.propertyAddress(selector: kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioDeviceID()
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr else {
            return nil
        }

        return deviceID
    }

    private func isInputDevice(_ deviceID: AudioDeviceID) throws -> Bool {
        var address = Self.propertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeInput
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)

        guard status == noErr else {
            return false
        }

        return dataSize > 0
    }

    private func deviceName(for deviceID: AudioDeviceID) throws -> String? {
        var address = Self.propertyAddress(selector: kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name)

        guard status == noErr else {
            return nil
        }

        return name?.takeUnretainedValue() as String?
    }

    private static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
