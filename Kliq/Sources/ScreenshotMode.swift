#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: renders the UI to PNGs for docs/screenshots, then quits.
///
///   Kliq.app/Contents/MacOS/Kliq -KliqScreenshots /path/to/dir
///
/// The popover is shown in a popover-style panel (the real one only opens from
/// a click on the menu bar), and each window captures itself, which needs no
/// Screen Recording permission.
@MainActor
enum ScreenshotMode {
    private static var panels: [NSWindow] = []

    static func runIfRequested() -> Bool {
        guard let path = UserDefaults.standard.string(forKey: "KliqScreenshots") else { return false }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            await capture(into: dir)
            NSApp.terminate(nil)
        }
        return true
    }

    private static func capture(into dir: URL) async {
        let controller = KliqController.shared
        writeMenuBarIcons(to: dir.appendingPathComponent("menubar-icon.png"))

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            await showPopover(PopoverView(controller: controller), file: dir.appendingPathComponent("popover-\(name).png"))
            if name == "light" {
                await showPopover(PopoverView(controller: controller, forcesAccessBanner: true),
                                  file: dir.appendingPathComponent("popover-no-access-\(name).png"))
            }
            for section in SettingsSection.allCases {
                SettingsWindowController.show(section: section)
                await pause(0.8)
                if let window = SettingsWindowController.window {
                    save(window, to: dir.appendingPathComponent("settings-\(section.rawValue)-\(name).png"))
                }
            }
            SettingsWindowController.window?.orderOut(nil)
        }
    }

    private static func showPopover<V: View>(_ view: V, file: URL) async {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - size.width - 80, y: screen.maxY - 8))
        }
        panel.orderFrontRegardless()
        panels.append(panel)
        await pause(1.0)
        save(panel, to: file)
        panel.orderOut(nil)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Capture

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImage` looked up at runtime (it's marked obsolete in
    /// newer SDKs but still captures an app's own windows).
    private static let createImage: CreateImage? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    /// While the screen is locked the window server draws windows blank, so
    /// captures fall back to drawing the views directly.
    private static var screenIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func save(_ window: NSWindow, to url: URL) {
        let includingWindow: UInt32 = 1 << 3, bestResolution: UInt32 = 1 << 3
        if !screenIsLocked, let createImage,
           let image = createImage(.null, includingWindow, CGWindowID(window.windowNumber), bestResolution)?
               .takeRetainedValue() {
            write(NSBitmapImageRep(cgImage: image), to: url)
            return
        }
        // Fallback without the window server: no vibrancy or shadow, so a
        // plain window background is painted underneath.
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        write(rep, to: url)
        NSLog("Kliq screenshots: used the fallback renderer for \(url.lastPathComponent)")
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Both states of the menu bar icon, on a light and a dark menu bar, at 4x.
    private static func writeMenuBarIcons(to url: URL) {
        let scale: CGFloat = 4
        let cell = NSSize(width: 44, height: 24)
        let size = NSSize(width: cell.width * 2 * scale, height: cell.height * 2 * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, (bar, ink)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black),
                                  (NSColor(white: 0.16, alpha: 1), NSColor.white)].enumerated() {
            let y = CGFloat(1 - row) * cell.height * scale
            bar.setFill()
            NSRect(x: 0, y: y, width: size.width, height: cell.height * scale).fill()
            for (column, image) in [MenuBarIcon.on, MenuBarIcon.off].enumerated() {
                let target = NSRect(x: (CGFloat(column) * cell.width + 13) * scale, y: y + 3 * scale,
                                    width: 18 * scale, height: 18 * scale)
                let tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    ink.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: target)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        write(rep, to: url)
    }
}
#endif
