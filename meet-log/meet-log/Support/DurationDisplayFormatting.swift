import Foundation

extension Duration {
    var mediaDurationDisplayString: String {
        let totalSeconds = max(0, Int(components.seconds))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d hr %02d min", hours, minutes)
        }

        if minutes > 0 {
            return String(format: "%d min %02d sec", minutes, seconds)
        }

        return String(format: "%d sec", seconds)
    }
}
