import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, sounds, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .sounds: return "Sounds"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .sounds: return "speaker.wave.2.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .sounds: return Theme.accent
        case .about: return .blue
        }
    }
}

final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var section: SettingsSection = .general
}

/// Kliq has no Dock icon, and on notched MacBooks a crowded menu bar can hide
/// its icon, so the settings window opens on first launch, at launch when the
/// menu bar icon is turned off, and whenever Kliq is opened again while running.
@MainActor
enum SettingsWindowController {
    private(set) static var window: NSWindow?

    static func show(section: SettingsSection? = nil) {
        if let section { SettingsNavigation.shared.section = section }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: .shared, navigation: .shared))
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Kliq Settings"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            newWindow.titlebarAppearsTransparent = true
            newWindow.toolbarStyle = .unified
            newWindow.isReleasedWhenClosed = false
            newWindow.setContentSize(NSSize(width: 740, height: 560))
            newWindow.center()
            newWindow.setFrameAutosaveName("KliqSettings")
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var controller: KliqController
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { navigation.section }, set: { if let s = $0 { navigation.section = s } })) {
                ForEach(SettingsSection.allCases) { section in
                    Label {
                        Text(section.title)
                    } icon: {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(section.tint.gradient))
                    }
                    .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            Group {
                switch navigation.section {
                case .general: GeneralPane(controller: controller)
                case .sounds: SoundsPane(controller: controller)
                case .about: AboutPane(controller: controller)
                }
            }
            .navigationTitle(navigation.section.title)
        }
        .frame(minWidth: 700, minHeight: 520)
        .onAppear {
            controller.rescanProfiles()
            controller.refreshLaunchAtLogin()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            controller.rescanProfiles()
            controller.refreshLaunchAtLogin()
            controller.refreshPermissions()
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var controller: KliqController

    var body: some View {
        Form {
            Section {
                Toggle("Sounds", isOn: $controller.isEnabled)
                Toggle("Launch at login", isOn: Binding(get: { controller.launchAtLogin },
                                                        set: { controller.setLaunchAtLogin($0) }))
                Toggle("Show menu bar icon", isOn: $controller.showMenuBarIcon)
            } footer: {
                if let error = controller.launchAtLoginError {
                    Text("Couldn't change the login item: \(error)")
                        .foregroundStyle(.orange)
                } else if controller.launchAtLoginNeedsApproval {
                    Text("Approve Kliq in System Settings → General → Login Items to finish.")
                } else if !controller.showMenuBarIcon {
                    Text("With the icon hidden, open Kliq again from Applications or Spotlight to get back here.")
                }
            }
            .tint(Theme.accent)

            Section {
                LabeledContent("Turn Kliq on or off") {
                    ShortcutRecorder(shortcut: $controller.toggleShortcut)
                }
            } footer: {
                Text("Works in any app. Click the shortcut to record a new one; press ⌫ to clear it.")
            }

            Section {
                LabeledContent("Input Monitoring") {
                    if controller.inputMonitoringGranted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant Access…", action: controller.fixInputMonitoring)
                    }
                }
            } footer: {
                Text("Kliq only uses the fact that a key was pressed. It never records what you type.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Click to record a new global shortcut. Esc cancels, ⌫ clears.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hovering = false

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type shortcut…" : (shortcut?.displayString ?? "Record Shortcut"))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(recording ? Theme.onAccent : (shortcut == nil ? Color.secondary : Color.primary))
                .frame(minWidth: 92)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(recording ? Theme.accent : (hovering ? Theme.fillHover : Theme.fill)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(recording ? Color.clear : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .kliqAnimation(value: recording)
        .onDisappear(perform: stop)
        .accessibilityLabel("Shortcut")
        .accessibilityValue(shortcut?.displayString ?? "None")
    }

    private func start() {
        recording = true
        HotKey.shared.unregister() // so the current shortcut can be recorded again
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Esc
                stop()
            case 51, 117: // Delete, Forward Delete
                shortcut = nil
                stop()
            default:
                guard let new = Shortcut(event: event) else {
                    NSSound.beep()
                    return nil
                }
                shortcut = new
                stop()
            }
            return nil
        }
    }

    private func stop() {
        guard recording || monitor != nil else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotKey.shared.register(shortcut)
    }
}

// MARK: - Sounds

private struct SoundsPane: View {
    @ObservedObject var controller: KliqController
    @State private var confirmingRemoval: SoundProfile?

    private var selected: SoundProfile { controller.soundProfile }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Sound")
                        ProfileGrid(controller: controller, columns: 3, large: true)
                    }
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Intensity")
                            IntensityControl(selection: $controller.intensity)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Volume")
                            VolumeSlider(value: $controller.volume)
                                .padding(.top, 5)
                        }
                    }
                }
                .padding(20)
            }

            Divider()
            detailBar
        }
        .confirmationDialog("Remove “\(confirmingRemoval?.displayName ?? "")”?",
                            isPresented: Binding(get: { confirmingRemoval != nil },
                                                 set: { if !$0 { confirmingRemoval = nil } }),
                            presenting: confirmingRemoval) { profile in
            Button("Move to Trash", role: .destructive) { controller.removeProfile(profile) }
        } message: { _ in
            Text("Its folder is moved to the Trash. You can import the pack again later.")
        }
    }

    private var detailBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selected.displayName)
                    .font(.system(size: 13, weight: .semibold))
                statusLine
            }
            Spacer()
            Picker("Type", selection: Binding(get: { selected.type },
                                              set: { controller.setType($0, for: selected) })) {
                ForEach(ProfileType.allCases) { type in
                    Text(type.displayName).tag(Optional(type))
                }
                Divider()
                Text("None").tag(ProfileType?.none)
            }
            .fixedSize()
            .help("The tag shown on this sound's card")

            Button("Remove…") { confirmingRemoval = selected }
                .disabled(!selected.isImported || controller.isImporting)
                .help(selected.isImported ? "Move this profile to the Trash" : "Built-in sounds can't be removed")
            Button("Import…", action: chooseImport)
                .keyboardShortcut("o")
                .disabled(controller.isImporting)
                .help("Import a Mechvibes pack (folder or .zip) or a Kliq profile folder")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch controller.importState {
        case .importing(let name):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                Text("Importing \(name)…")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .lineLimit(2)
        case .imported(let name) where name == selected.displayName:
            Text("Imported. \(selected.summary)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        default:
            Text(selected.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Sound Pack"
        panel.message = "Choose a Mechvibes pack (folder or .zip) or a Kliq profile folder."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.importProfile(from: url)
    }
}

// MARK: - About

enum KliqInfo {
    /// Set this to the project's GitHub page to show a link in About.
    static let repositoryURL = URL(string: "https://github.com/6vansh9/kliq")

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }
}

private struct AboutPane: View {
    @ObservedObject var controller: KliqController

    private var credited: [SoundProfile] { controller.availableProfiles.filter { $0.credit != nil } }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    Text("Kliq")
                        .font(.system(size: 22, weight: .bold))
                    Text(KliqInfo.version)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("Mechanical keyboard sounds for your Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let url = KliqInfo.repositoryURL {
                        Link(destination: url) {
                            Label("View on GitHub", systemImage: "arrow.up.right.square")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .tint(Theme.accent)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section("Sound credits") {
                LabeledContent("Creamy, Thock, Pop, Clicky, Typewriter") {
                    Text("Synthesized for Kliq")
                }
                ForEach(credited) { profile in
                    if let credit = profile.credit {
                        LabeledContent {
                            Text(credit.licenseFound ? "Licensed" : "Personal use only")
                                .foregroundStyle(.secondary)
                        } label: {
                            Text(profile.displayName)
                            Text("\(credit.source) pack “\(credit.packName)”"
                                 + (credit.author.map { " by \($0)" } ?? ""))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
