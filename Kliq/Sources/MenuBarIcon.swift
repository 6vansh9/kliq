import AppKit

/// Kliq's menu bar icon: a minimal keycap with a small sound wave, drawn as
/// an 18 × 18 pt template image (so it's crisp at every scale and follows the
/// menu bar's color). The keycap is filled when Kliq is on, outlined when off.
enum MenuBarIcon {
    static let on = make(filled: true)
    static let off = make(filled: false)

    static func image(isOn: Bool) -> NSImage { isOn ? on : off }

    private static func make(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            // Keycap body (slightly wider at the base) and its top face.
            // The top face sits high in the body, like a keycap seen from the front.
            let body = NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 10.5, height: 10.5), xRadius: 2.6, yRadius: 2.6)
            let top = NSBezierPath(roundedRect: NSRect(x: 3, y: 5, width: 6.5, height: 5.7), xRadius: 1.5, yRadius: 1.5)
            if filled {
                body.fill()
                // Cut the top face out as a thin outline so the cap still reads as a key.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                top.lineWidth = 1.1
                top.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                body.lineWidth = 1.3
                body.stroke()
                top.lineWidth = 1.1
                top.stroke()
            }
            // Two short arcs to the right: the sound.
            for (radius, width) in [(3.2, 1.3), (5.5, 1.2)] as [(CGFloat, CGFloat)] {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: 11.5, y: 12.5), radius: radius, startAngle: -5, endAngle: 85)
                arc.lineWidth = width
                arc.lineCapStyle = .round
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = filled ? "Kliq (on)" : "Kliq (off)"
        return image
    }
}
