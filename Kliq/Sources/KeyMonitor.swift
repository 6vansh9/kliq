import CoreGraphics
import Darwin
import Foundation

/// Watches system-wide key presses with a listen-only event tap.
///
/// Each press and release is reported with its time and virtual keycode. The
/// keycode exists only so each key can have its own sound: it is never logged,
/// stored or saved. Modifier keys (shift, caps lock, command, …) arrive as
/// flags-changed events and are reported as presses and releases too.
///
/// The tap's run loop source is added to the main run loop, so `onKeyDown`
/// and `onKeyUp` are always called on the main thread.
final class KeyMonitor {
    /// Called on the main thread with the `mach_absolute_time()` and keycode of each key press.
    var onKeyDown: ((UInt64, UInt16) -> Void)?
    /// Called on the main thread with the keycode of each key release.
    var onKeyUp: ((UInt16) -> Void)?
    /// Called on the main thread whenever the tap is created or lost.
    var onStateChange: ((Bool) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    /// Modifier keys currently held, to tell a press from a release when both
    /// keys of a pair (left and right shift) share one flag.
    private var heldModifiers: Set<UInt16> = []

    private static let capsLockKeyCode: UInt16 = 57
    private static let modifierFlags: [UInt16: CGEventFlags] = [
        56: .maskShift, 60: .maskShift,
        59: .maskControl, 62: .maskControl,
        58: .maskAlternate, 61: .maskAlternate,
        55: .maskCommand, 54: .maskCommand,
        63: .maskSecondaryFn,
    ]

    var isActive: Bool { tap != nil }

    deinit {
        stop()
    }

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt (first time only) and adds Kliq to the Input Monitoring list.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestListenEventAccess() }

    /// Creates the tap, or keeps retrying every 2 seconds until access is granted.
    func start() {
        guard tap == nil else { return }
        if createTap() {
            Log.keys.info("Event tap created")
            retryTimer?.invalidate()
            retryTimer = nil
            onStateChange?(true)
        } else if retryTimer == nil {
            Log.keys.notice("Event tap unavailable (no Input Monitoring access?). Retrying every 2 s")
            let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self, self.createTap() else { return }
                Log.keys.info("Event tap created after retry")
                self.retryTimer?.invalidate()
                self.retryTimer = nil
                self.onStateChange?(true)
            }
            RunLoop.main.add(timer, forMode: .common)
            retryTimer = timer
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        removeTap()
    }

    /// Recreates the tap from scratch, e.g. after wake or after access was revoked and re-granted.
    func restart() {
        removeTap()
        onStateChange?(false)
        start()
    }

    /// Makes sure an existing tap is still enabled (macOS can silently disable it).
    func ensureEnabled() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // MARK: Tap management

    private func createTap() -> Bool {
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged]
            .reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: kliqKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source
        return true
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    // MARK: Called from the C callback (main thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown:
            // Holding a key produces autorepeat events; only the first press counts.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            onKeyDown?(mach_absolute_time(), Self.keyCode(of: event))
        case .keyUp:
            onKeyUp?(Self.keyCode(of: event))
        case .flagsChanged:
            handleModifier(event)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Log.keys.notice("Event tap disabled by the system (\(type.rawValue)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            break
        }
    }

    private static func keyCode(of event: CGEvent) -> UInt16 {
        UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    }

    private func handleModifier(_ event: CGEvent) {
        let code = Self.keyCode(of: event)
        if code == Self.capsLockKeyCode {
            // Caps lock sends one event per press (toggling the light), none on release.
            onKeyDown?(mach_absolute_time(), code)
            return
        }
        guard let flag = Self.modifierFlags[code] else { return }
        if event.flags.contains(flag), !heldModifiers.contains(code) {
            heldModifiers.insert(code)
            onKeyDown?(mach_absolute_time(), code)
        } else if heldModifiers.remove(code) != nil {
            onKeyUp?(code)
        }
    }
}

/// C-compatible event tap callback. Must not capture context, so the monitor
/// is passed through `refcon`. Always passes the event through unchanged.
private func kliqKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
