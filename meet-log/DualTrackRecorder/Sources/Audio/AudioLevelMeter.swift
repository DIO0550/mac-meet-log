import AVFoundation
import Foundation

struct AudioLevelMeter {
    private let waveformSampleCount: Int
    private let minimumEventInterval: TimeInterval
    private var lastEmissionDate: Date?

    init(waveformSampleCount: Int = 48, minimumEventInterval: TimeInterval = 1.0 / 15.0) {
        self.waveformSampleCount = waveformSampleCount
        self.minimumEventInterval = minimumEventInterval
    }

    mutating func events(for buffer: AVAudioPCMBuffer, track: RecordingTrack, at date: Date = Date()) -> [RecorderEvent] {
        guard shouldEmit(at: date) else {
            return []
        }

        lastEmissionDate = date

        let metrics = Self.metrics(from: buffer, waveformSampleCount: waveformSampleCount)
        return [
            .level(AudioLevelSnapshot(track: track, peak: metrics.peak, rms: metrics.rms)),
            .waveform(WaveformSnapshot(track: track, samples: metrics.waveform))
        ]
    }

    static func metrics(from buffer: AVAudioPCMBuffer, waveformSampleCount: Int = 48) -> (
        peak: Float,
        rms: Float,
        waveform: [Float]
    ) {
        guard
            let channelData = buffer.floatChannelData,
            buffer.frameLength > 0,
            buffer.format.channelCount > 0
        else {
            return (0, 0, Array(repeating: 0, count: waveformSampleCount))
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var peak: Float = 0
        var sumOfSquares: Float = 0
        var monoSamples = Array(repeating: Float.zero, count: frameCount)

        for channel in 0..<channelCount {
            let samples = channelData[channel]

            for frame in 0..<frameCount {
                let sample = samples[frame]
                let absoluteSample = abs(sample)
                peak = max(peak, absoluteSample)
                sumOfSquares += sample * sample
                monoSamples[frame] += sample / Float(channelCount)
            }
        }

        let sampleCount = max(channelCount * frameCount, 1)
        let rms = sqrt(sumOfSquares / Float(sampleCount))

        return (
            min(peak, 1),
            min(rms, 1),
            downsample(samples: monoSamples, targetCount: waveformSampleCount)
        )
    }

    private func shouldEmit(at date: Date) -> Bool {
        guard let lastEmissionDate else {
            return true
        }

        return date.timeIntervalSince(lastEmissionDate) >= minimumEventInterval
    }

    private static func downsample(samples: [Float], targetCount: Int) -> [Float] {
        guard targetCount > 0 else {
            return []
        }

        guard !samples.isEmpty else {
            return Array(repeating: 0, count: targetCount)
        }

        let bucketSize = max(Double(samples.count) / Double(targetCount), 1)

        return (0..<targetCount).map { bucketIndex in
            let start = Int(Double(bucketIndex) * bucketSize)
            let end = min(Int(Double(bucketIndex + 1) * bucketSize), samples.count)

            guard start < end else {
                return 0
            }

            let bucket = samples[start..<end]
            let strongest = bucket.max { abs($0) < abs($1) } ?? 0
            return max(min(strongest, 1), -1)
        }
    }
}
