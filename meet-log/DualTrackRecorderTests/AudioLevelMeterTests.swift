import AVFoundation
import CoreAudio
import Testing
@testable import DualTrackRecorder

struct AudioLevelMeterTests {
    @Test(arguments: [false, true], [AVAudioChannelCount(1), 2])
    func emptyBufferDoesNotImplyAudioIsBeingSupplied(interleaved: Bool, channelCount: AVAudioChannelCount) throws {
        let buffer = try makeBuffer(
            samples: Array(repeating: 0, count: Int(channelCount)),
            channelCount: channelCount,
            interleaved: interleaved
        )
        buffer.frameLength = 0
        var meter = AudioLevelMeter()
        #expect(meter.events(for: buffer, track: .microphone).isEmpty)

        let metrics = AudioLevelMeter.metrics(from: buffer, waveformSampleCount: 4)
        #expect(metrics.peak == 0)
        #expect(metrics.rms == 0)
        #expect(metrics.waveform == [0, 0, 0, 0])

        buffer.frameLength = 1
        #expect(meter.events(for: buffer, track: .microphone).count == 2)
    }

    @Test(arguments: [false, true], [AVAudioChannelCount(1), 2])
    func silentBufferProducesZeroMetrics(interleaved: Bool, channelCount: AVAudioChannelCount) throws {
        let buffer = try makeBuffer(
            samples: Array(repeating: 0, count: 4 * Int(channelCount)),
            channelCount: channelCount,
            interleaved: interleaved
        )

        let metrics = AudioLevelMeter.metrics(from: buffer, waveformSampleCount: 4)

        #expect(metrics.peak == 0)
        #expect(metrics.rms == 0)
        #expect(metrics.waveform == [0, 0, 0, 0])
    }

    @Test(arguments: [false, true])
    func peakBufferProducesPeakAndRMS(interleaved: Bool) throws {
        let buffer = try makeBuffer(samples: [0, 0.5, -1, 0.25], channelCount: 1, interleaved: interleaved)

        let metrics = AudioLevelMeter.metrics(from: buffer, waveformSampleCount: 2)

        #expect(metrics.peak == 1)
        #expect(metrics.rms == Float(1.3125 / 4).squareRoot())
        #expect(metrics.waveform == [0.5, -1])
    }

    @Test(arguments: [false, true])
    func stereoBufferDownmixesWaveform(interleaved: Bool) throws {
        let buffer = try makeBuffer(
            samples: [0, 0.5, 0.25, 0, -0.5, 0.25, 1, -0.5],
            channelCount: 2,
            interleaved: interleaved
        )

        let metrics = AudioLevelMeter.metrics(from: buffer, waveformSampleCount: 4)

        #expect(metrics.peak == 1)
        #expect(metrics.rms == Float(1.875 / 8).squareRoot())
        #expect(metrics.waveform == [0.25, 0.125, -0.125, 0.25])
    }

    @Test(arguments: [AVAudioChannelCount(1), 2], [2, 4, 8])
    func sameAudioProducesIdenticalMetricsInBothLayouts(channelCount: AVAudioChannelCount, waveformSampleCount: Int) throws {
        let samples: [Float] = [0, 0.5, 0.25, 0, -0.5, 0.25, 1, -0.5]
        let planar = try makeBuffer(samples: samples, channelCount: channelCount)
        let interleaved = try makeBuffer(samples: samples, channelCount: channelCount, interleaved: true)

        let planarMetrics = AudioLevelMeter.metrics(from: planar, waveformSampleCount: waveformSampleCount)
        let interleavedMetrics = AudioLevelMeter.metrics(from: interleaved, waveformSampleCount: waveformSampleCount)

        #expect(interleavedMetrics.peak == planarMetrics.peak)
        #expect(interleavedMetrics.rms == planarMetrics.rms)
        #expect(interleavedMetrics.waveform == planarMetrics.waveform)
    }

    @Test(arguments: [false, true], [AVAudioChannelCount(1), 2])
    func peakInFinalFrameIsIncluded(interleaved: Bool, channelCount: AVAudioChannelCount) throws {
        let samples = Array(repeating: Float.zero, count: 3 * Int(channelCount))
            + Array(repeating: Float(1), count: Int(channelCount))
        let buffer = try makeBuffer(samples: samples, channelCount: channelCount, interleaved: interleaved)

        let metrics = AudioLevelMeter.metrics(from: buffer, waveformSampleCount: 4)

        #expect(metrics.peak == 1)
        #expect(metrics.rms == 0.5)
        #expect(metrics.waveform == [0, 0, 0, 1])
    }

    @Test(arguments: [AVAudioCommonFormat.pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32], [false, true])
    func unsupportedPCMFormatsProduceZeroMetrics(commonFormat: AVAudioCommonFormat, interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: commonFormat, sampleRate: 44_100, channels: 2, interleaved: interleaved
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            let data = try #require(audioBuffer.mData)
            data.initializeMemory(as: UInt8.self, repeating: 1, count: Int(audioBuffer.mDataByteSize))
        }
        #expect(buffer.floatChannelData == nil)

        let metrics = AudioLevelMeter.metrics(from: buffer, waveformSampleCount: 4)

        #expect(metrics.peak == 0)
        #expect(metrics.rms == 0)
        #expect(metrics.waveform == [0, 0, 0, 0])
    }

    // Input samples use frame-major order independently of the buffer layout.
    private func makeBuffer(
        samples: [Float],
        channelCount: AVAudioChannelCount,
        interleaved: Bool = false
    ) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(samples.count / Int(channelCount))
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: channelCount, interleaved: interleaved
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount

        // Fill raw storage so the fixture does not repeat the meter's stride
        // calculation and hide a channel-layout bug in both implementations.
        if interleaved {
            let data = try #require(buffer.mutableAudioBufferList.pointee.mBuffers.mData)
                .assumingMemoryBound(to: Float.self)
            for (index, sample) in samples.enumerated() {
                data[index] = sample
            }

            return buffer
        }

        let channelData = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channelCount) {
            for frame in 0..<Int(frameCount) {
                channelData[channel][frame] = samples[(frame * Int(channelCount)) + channel]
            }
        }

        return buffer
    }
}
