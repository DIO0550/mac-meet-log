import Foundation

public enum RecorderEvent: Equatable, Sendable {
    case stateChanged(RecorderState)
    case level(AudioLevelSnapshot)
    case waveform(WaveformSnapshot)
}

public struct AudioLevelSnapshot: Equatable, Sendable {
    public let track: RecordingTrack
    public let peak: Float
    public let rms: Float

    public init(track: RecordingTrack, peak: Float, rms: Float) {
        self.track = track
        self.peak = peak
        self.rms = rms
    }
}

public struct WaveformSnapshot: Equatable, Sendable {
    public let track: RecordingTrack
    public let samples: [Float]

    public init(track: RecordingTrack, samples: [Float]) {
        self.track = track
        self.samples = samples
    }
}
