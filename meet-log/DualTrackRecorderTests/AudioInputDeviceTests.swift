import Testing
@testable import DualTrackRecorder

struct AudioInputDeviceTests {
    @Test func defaultDeviceDisplayNameIncludesDefaultMarker() {
        let device = AudioInputDevice(id: "default-input", name: "MacBook Pro Microphone", isDefault: true)

        #expect(device.displayName == "MacBook Pro Microphone (Default)")
    }

    @Test func explicitDeviceDisplayNameUsesDeviceNameOnly() {
        let device = AudioInputDevice(id: "usb-input", name: "USB Microphone", isDefault: false)

        #expect(device.displayName == "USB Microphone")
    }

    @Test func selectionDistinguishesSystemDefaultFromExplicitDeviceID() {
        let defaultSelection = MicrophoneInputDeviceSelection.systemDefault
        let explicitSelection = MicrophoneInputDeviceSelection.device(id: "usb-input")

        #expect(defaultSelection.deviceID == nil)
        #expect(explicitSelection.deviceID == "usb-input")
        #expect(defaultSelection != explicitSelection)
    }
}
