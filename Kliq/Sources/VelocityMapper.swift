import Foundation

/// Turns a raw force reading into a 0–1 velocity, adapting to the user's own
/// typing range over the last few hundred keystrokes.
///
/// Not used yet: it's here for a `ForceSource` backed by a hardware sensor.
/// Readings are linear amplitudes (converted to dB internally); until enough
/// keystrokes are recorded, -50 dB counts as soft and -18 dB as hard.
struct VelocityMapper {
    static let historySize = 300
    static let minSamplesForAdaptiveRange = 25
    static let defaultSoftDB = -50.0
    static let defaultHardDB = -18.0
    static let minSpreadDB = 6.0

    private var history: [Double] = []
    private var nextIndex = 0

    init() {
        history.reserveCapacity(Self.historySize)
    }

    static func decibels(forReading reading: Float) -> Double {
        20 * log10(max(Double(reading), 1e-6))
    }

    /// Records the keystroke and returns its velocity. `sensitivity` (0–1,
    /// 0.5 neutral) shifts the result toward soft or hard.
    mutating func velocity(forReading reading: Float, sensitivity: Double = 0.5) -> Double {
        let db = Self.decibels(forReading: reading)
        record(db)

        let (low, high) = range()
        let normalized = (db - low) / (high - low)
        let velocity = normalized + (sensitivity - 0.5) * 0.6
        return min(max(velocity, 0), 1)
    }

    private mutating func record(_ db: Double) {
        if history.count < Self.historySize {
            history.append(db)
        } else {
            history[nextIndex] = db
        }
        nextIndex = (nextIndex + 1) % Self.historySize
    }

    private func range() -> (low: Double, high: Double) {
        guard history.count >= Self.minSamplesForAdaptiveRange else {
            return (Self.defaultSoftDB, Self.defaultHardDB)
        }
        let sorted = history.sorted()
        var low = Self.percentile(0.10, of: sorted)
        var high = Self.percentile(0.90, of: sorted)
        if high - low < Self.minSpreadDB {
            let mid = (low + high) / 2
            low = mid - Self.minSpreadDB / 2
            high = mid + Self.minSpreadDB / 2
        }
        return (low, high)
    }

    private static func percentile(_ p: Double, of sorted: [Double]) -> Double {
        let index = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[index]
    }
}
