import AppKit
import SwiftUI

/// The menu bar popover: on/off, sound, intensity and volume.
struct PopoverView: View {
    @ObservedObject var controller: KliqController
    /// For screenshots of the banner; normally the banner follows the permission.
    var forcesAccessBanner = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if forcesAccessBanner || !controller.inputMonitoringGranted {
                AccessBanner(action: controller.fixInputMonitoring)
            }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Sound")
                    ProfileGrid(controller: controller, columns: 2, maxVisibleRows: 3.5)
                    if controller.profileHasKeyUpSounds {
                        HStack {
                            Text("Key-up sounds")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            KliqSwitch(isOn: $controller.keyUpSounds, label: "Key-up sounds")
                        }
                        .padding(.top, 2)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Intensity")
                    IntensityControl(selection: $controller.intensity)
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Volume")
                    VolumeSlider(value: $controller.volume)
                }
            }
            .opacity(controller.isEnabled ? 1 : 0.5)
            .kliqAnimation(value: controller.isEnabled)

            if let message = controller.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            controller.refreshPermissions()
            controller.rescanProfiles()
        }
        // The popover stays alive between openings, so also rescan each time it
        // comes to the front; new imports show up without a restart.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            controller.refreshPermissions()
            controller.rescanProfiles()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Kliq")
                    .font(.system(size: 15, weight: .bold))
                Text(controller.isEnabled ? controller.soundProfile.displayName : "Off")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer()
            KliqSwitch(isOn: $controller.isEnabled, style: .power,
                       label: controller.isEnabled ? "Turn Kliq off" : "Turn Kliq on")
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Divider().opacity(0.6)
            HStack(spacing: 2) {
                QuietIconButton(systemImage: "gearshape", help: "Settings") {
                    SettingsWindowController.show()
                }
                QuietIconButton(systemImage: "folder", help: "Open Profiles Folder") {
                    controller.openProfilesFolder()
                }
                Spacer()
                if let shortcut = controller.toggleShortcut {
                    Text(shortcut.displayString)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .help("Turns Kliq on or off from any app")
                        .padding(.trailing, 4)
                }
                QuietIconButton(systemImage: "rectangle.portrait.and.arrow.right", help: "Quit Kliq") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            // Line the icons' glyphs up with the content edges.
            .padding(.horizontal, -7)
        }
        .padding(.bottom, -6)
    }
}
