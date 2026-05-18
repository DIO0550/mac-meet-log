import SwiftUI

struct RecorderLevelView: View {
    let level: RecorderLevelSnapshot
    let waveform: RecorderWaveform
    let isActive: Bool

    private var levelRows: [LevelRow] {
        [
            LevelRow(label: "System", value: level.systemAudio, tint: .blue),
            LevelRow(label: "Mic", value: level.microphone, tint: .green)
        ]
    }

    var body: some View {
        VStack(spacing: 14) {
            waveformView

            VStack(spacing: 9) {
                ForEach(levelRows) { row in
                    HStack(spacing: 10) {
                        Text(row.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)

                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(.quaternary)

                                Capsule()
                                    .fill(row.tint.gradient)
                                    .frame(width: max(6, geometry.size.width * clamped(row.value)))
                            }
                        }
                        .frame(height: 7)
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var waveformView: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 4) {
                ForEach(waveform.samples.indices, id: \.self) { index in
                    let sample = waveform.samples[index]

                    Capsule()
                        .fill(isActive ? Color.red.opacity(0.82) : Color.secondary.opacity(0.34))
                        .frame(
                            width: max(3, (geometry.size.width - 108) / CGFloat(max(waveform.samples.count, 1))),
                            height: max(5, geometry.size.height * CGFloat(clamped(sample)))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 72)
        .accessibilityLabel("Input waveform")
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

private struct LevelRow: Identifiable {
    let label: String
    let value: Double
    let tint: Color

    var id: String {
        label
    }
}
