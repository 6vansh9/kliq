import Foundation

/// Something that knows how hard a key was pressed, such as a future hardware
/// force sensor. Kliq has none today: every key plays at the user's chosen
/// `Intensity`.
///
/// To add one, conform to this protocol and set `KliqController.forceSource`.
/// A source that produces raw readings (pressure, amplitude) can feed them
/// through `VelocityMapper` to get a 0–1 velocity that adapts to the user's
/// own typing range. The sound engine picks the soft/medium/hard layer and
/// the playback level from the velocity, so it needs no changes.
protocol ForceSource: AnyObject {
    /// Velocity from 0 (lightest) to 1 (hardest) for the key press at
    /// `hostTime` (`mach_absolute_time()`), or nil if there's no reading.
    ///
    /// Called on the main thread from the key-down handler and must return
    /// immediately, since the sound plays right after.
    func velocity(forKeyPressAt hostTime: UInt64, keyCode: UInt16) -> Double?
}

/// The fixed strength every key plays at when no `ForceSource` is attached.
enum Intensity: String, CaseIterable, Identifiable {
    case soft, medium, hard

    static let `default` = Intensity.medium

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .soft: return "Soft"
        case .medium: return "Medium"
        case .hard: return "Hard"
        }
    }

    /// A velocity in the middle of this intensity's layer (see `SoundEngine.Layer`).
    var velocity: Double {
        switch self {
        case .soft: return 0.2
        case .medium: return 0.5
        case .hard: return 0.85
        }
    }
}
