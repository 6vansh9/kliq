import AppKit
import SwiftUI

@main
struct KliqApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // The scene reads only these two settings. Observing the whole controller here
    // re-renders the status item on every change and can spin SwiftUI's
    // MenuBarExtra update loop at 100% CPU.
    @AppStorage(KliqController.Keys.enabled) private var isEnabled = true
    @AppStorage(KliqController.Keys.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            PopoverView(controller: KliqController.shared)
        } label: {
            Image(nsImage: MenuBarIcon.image(isOn: isEnabled))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let controller = KliqController.shared
            #if DEBUG
            if ScreenshotMode.runIfRequested() { return }
            #endif
            // `open -a Kliq --args -KliqLaunchAtLogin YES` (or NO) sets the login
            // item from the command line; it has to be registered by the app itself.
            if UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["KliqLaunchAtLogin"] != nil {
                controller.setLaunchAtLogin(UserDefaults.standard.bool(forKey: "KliqLaunchAtLogin"))
                return
            }
            if controller.consumeFirstLaunch() || !controller.showMenuBarIcon {
                SettingsWindowController.show()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { SettingsWindowController.show() }
        return true
    }
}
