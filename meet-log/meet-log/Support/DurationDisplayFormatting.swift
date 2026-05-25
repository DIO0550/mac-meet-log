import Foundation

extension Duration {
    var mediaDurationDisplayString: String {
        let totalSeconds = max(0, components.seconds)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%lld hr %02lld min", hours, minutes)
        }

        if minutes > 0 {
            return String(format: "%lld min %02lld sec", minutes, seconds)
        }

        return String(format: "%lld sec", seconds)
    }
}
