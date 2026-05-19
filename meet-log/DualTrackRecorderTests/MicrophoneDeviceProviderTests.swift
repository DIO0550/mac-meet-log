import Testing
@testable import DualTrackRecorder

struct MicrophoneDeviceProviderTests {
    @Test func fakeProviderReturnsConfiguredDevices() throws {
        let expectedDevices = AudioInputDevice.previewDevices
        let provider = FakeMicrophoneDeviceProvider(devices: expectedDevices)

        #expect(try provider.devices() == expectedDevices)
    }

    @Test func fakeProviderPublishesDeviceChanges() async {
        let provider = FakeMicrophoneDeviceProvider(devices: [.builtInMicrophone])
        let changesTask = Task {
            var changes: [[AudioInputDevice]] = []

            for await devices in provider.deviceChanges() {
                changes.append(devices)

                if changes.count == 2 {
                    break
                }
            }

            return changes
        }

        await Task.yield()
        provider.send(AudioInputDevice.previewDevices)
        let changes = await changesTask.value

        #expect(changes == [[.builtInMicrophone], AudioInputDevice.previewDevices])
    }
}
