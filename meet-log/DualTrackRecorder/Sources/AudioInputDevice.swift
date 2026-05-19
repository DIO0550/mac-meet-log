import Foundation

public struct AudioInputDevice: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }

    public var displayName: String {
        if isDefault {
            return "\(name) (Default)"
        }

        return name
    }
}

public enum MicrophoneInputDeviceSelection: Equatable, Sendable {
    case systemDefault
    case device(id: AudioInputDevice.ID)

    public var deviceID: AudioInputDevice.ID? {
        switch self {
        case .systemDefault:
            nil
        case let .device(id):
            id
        }
    }
}

public extension AudioInputDevice {
    static let builtInMicrophone = AudioInputDevice(
        id: "built-in-microphone",
        name: "Built-in Microphone",
        isDefault: true
    )

    static let usbMicrophone = AudioInputDevice(
        id: "usb-microphone",
        name: "USB Microphone"
    )

    static let previewDevices: [AudioInputDevice] = [
        .builtInMicrophone,
        .usbMicrophone
    ]
}
