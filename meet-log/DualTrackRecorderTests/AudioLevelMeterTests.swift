import AVFoundation
import Testing
@testable import DualTrackRecorder

struct AudioLevelMeterTests {
    @Test func silentBufferProducesZeroMetrics() throws {
        let buffer = try makeBuffer(samples: [0, 0, 0, 0], channelCount: 1)

        let metrics = AudioLevelMeter.metrics(from: buffer, waveformSampleCount: 4)

        #expect(metrics.peak == 0)
        #expect(metrics.rms == 0)
        #expect(metrics.waveform == [0, 0, 0, 0])
    }

    @Test func peakBufferProducesPeakAndRMS() throws {
        let buffer = try makeBuffer(samples: [0, 0.5, -1, 0.25], channelCount: 1)

        let metrics = AudioLevelMeter.metrics(from: buffer, waveformSampleCount: 2)

        #expect(metrics.peak == 1)
        #expect(metrics.rms > 0)
        #expect(metrics.waveform.count == 2)
    }

    @Test func stereoBufferDownmixesWaveform() throws {
        let buffer = try makeBuffer(samples: [1, 1, -1, -1], channelCount: 2)

        let metrics = AudioLevelMeter.metrics(from: buffer, waveformSampleCount: 2)

        #expect(metrics.peak == 1)
        #expect(metrics.waveform.count == 2)
    }

    private func makeBuffer(samples: [Float], channelCount: AVAudioChannelCount) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(samples.count / Int(channelCount))
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: channelCount)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData else {
            throw RecorderError.captureFailed("Test buffer did not expose float channel data.")
        }

        for channel in 0..<Int(channelCount) {
            for frame in 0..<Int(frameCount) {
                channelData[channel][frame] = samples[(frame * Int(channelCount)) + channel]
            }
        }

        return buffer
    }
}
