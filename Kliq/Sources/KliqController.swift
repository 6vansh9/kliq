import AppKit
import Combine
import ServiceManagement

/// Owns the app state shown in the popover and wires the pieces together:
/// key press → velocity (a `ForceSource`, or the fixed `Intensity`) → play sound.
///
/// Everything here runs on the main thread.
@MainActor
final class KliqController: ObservableObject {
    static let shared = KliqController()

    static let inputMonitoringSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    enum Keys {
        static let enabled = "enabled"
        static let volume = "volume"
        static let intensity = "intensity"
        static let soundProfile = "soundProfile"
        static let keyUpSounds = "keyUpSounds"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let toggleShortcut = "toggleShortcut"
    }

    private static let healthCheckInterval: TimeInterval = 2.0

    // MARK: Settings (persisted)

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            applyEnabledState()
        }
    }
    @Published var volume: Double {
        didSet { defaults.set(volume, forKey: Keys.volume) }
    }
    /// How hard every key sounds (its velocity layer) while no `forceSource` is attached.
    @Published var intensity: Intensity {
        didSet {
            defaults.set(intensity.rawValue, forKey: Keys.intensity)
            if intensity != oldValue { previewSound() }
        }
    }
    @Published var soundProfile: SoundProfile {
        didSet {
            defaults.set(soundProfile.id, forKey: Keys.soundProfile)
            soundEngine.setProfile(soundProfile)
            profileHasKeyUpSounds = soundEngine.hasKeyUpSounds
            if soundProfile != oldValue { previewSound() }
        }
    }
    /// Plays the profile's `up_N` sounds quietly when keys are released.
    @Published var keyUpSounds: Bool {
        didSet { defaults.set(keyUpSounds, forKey: Keys.keyUpSounds) }
    }
    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon) }
    }
    /// System-wide shortcut that turns Kliq on or off (default ⌃⌥K); nil when cleared.
    @Published var toggleShortcut: Shortcut? {
        didSet {
            defaults.set(toggleShortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(),
                         forKey: Keys.toggleShortcut)
            HotKey.shared.register(toggleShortcut)
        }
    }

    /// True only the very first time Kliq runs; reading it marks the first launch as done.
    func consumeFirstLaunch() -> Bool {
        let first = !defaults.bool(forKey: Keys.hasLaunchedBefore)
        defaults.set(true, forKey: Keys.hasLaunchedBefore)
        return first
    }

    // MARK: Status

    /// Built-in profiles followed by imported ones. Refreshed by `rescanProfiles()`.
    @Published private(set) var availableProfiles: [SoundProfile] = SoundProfile.builtIn
    @Published private(set) var profileHasKeyUpSounds = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var importState: ImportState = .idle
    /// Mirrors `SMAppService.mainApp`; refreshed whenever settings are shown.
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published private(set) var launchAtLoginError: String?

    enum ImportState: Equatable {
        case idle
        case importing(String)
        case imported(String)
        case failed(String)
    }

    var inputMonitoringDetail: String {
        "Needed to hear key presses. If sounds don't start after allowing, quit and reopen Kliq."
    }

    // MARK: Components

    private let defaults = UserDefaults.standard
    private let keyMonitor = KeyMonitor()
    private let soundEngine: SoundEngine

    /// Hardware force sensor, if one is ever attached. When nil (today, always)
    /// or when it has no reading, keys play at `intensity`.
    var forceSource: ForceSource?

    private var hadListenAccess = false
    private var healthTimer: Timer?
    private var wakeObservers: [NSObjectProtocol] = []

    private init() {
        defaults.register(defaults: [
            Keys.enabled: true,
            Keys.volume: 0.8,
            Keys.intensity: Intensity.default.rawValue,
            Keys.soundProfile: SoundProfile.default.id,
            Keys.keyUpSounds: false,
            Keys.showMenuBarIcon: true,
        ])
        isEnabled = defaults.bool(forKey: Keys.enabled)
        volume = defaults.double(forKey: Keys.volume)
        intensity = Intensity(rawValue: defaults.string(forKey: Keys.intensity) ?? "") ?? .default
        let profiles = SoundProfile.builtIn + SoundProfile.scanImported()
        let savedID = defaults.string(forKey: Keys.soundProfile)
        let profile = profiles.first { $0.id == savedID } ?? .default
        availableProfiles = profiles
        soundProfile = profile
        soundEngine = SoundEngine(profile: profile)
        profileHasKeyUpSounds = soundEngine.hasKeyUpSounds
        keyUpSounds = defaults.bool(forKey: Keys.keyUpSounds)
        showMenuBarIcon = defaults.bool(forKey: Keys.showMenuBarIcon)
        if let data = defaults.data(forKey: Keys.toggleShortcut) {
            toggleShortcut = data.isEmpty ? nil : (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? .default
        } else {
            toggleShortcut = .default
        }
        HotKey.shared.onPress = { [weak self] in
            MainActor.assumeIsolated { self?.isEnabled.toggle() }
        }
        HotKey.shared.register(toggleShortcut)
        refreshLaunchAtLogin()

        wireCallbacks()
        if !KeyMonitor.hasPermission {
            KeyMonitor.requestPermission()
        }
        keyMonitor.start()
        refreshPermissions()
        applyEnabledState()
        startHealthChecks()
        observeWake()
    }

    private func wireCallbacks() {
        soundEngine.onError = { [weak self] message in
            MainActor.assumeIsolated { self?.errorMessage = message }
        }
        // Key codes are used only to pick each key's sound; they're never logged or stored.
        keyMonitor.onKeyDown = { [weak self] time, keyCode in
            MainActor.assumeIsolated { self?.handleKeyDown(at: time, keyCode: keyCode) }
        }
        keyMonitor.onKeyUp = { [weak self] keyCode in
            MainActor.assumeIsolated { self?.handleKeyUp(keyCode: keyCode) }
        }
        keyMonitor.onStateChange = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    // MARK: Permissions

    func refreshPermissions() {
        let listenAccess = KeyMonitor.hasPermission
        // Access was revoked while running: drop the dead tap and wait for it to come back.
        // Only on a true → false transition, since the preflight result can lag behind a grant.
        if hadListenAccess, !listenAccess, keyMonitor.isActive {
            keyMonitor.restart()
        }
        hadListenAccess = listenAccess
        let granted = keyMonitor.isActive || listenAccess
        if granted != inputMonitoringGranted { inputMonitoringGranted = granted }
    }

    func fixInputMonitoring() {
        KeyMonitor.requestPermission()
        NSWorkspace.shared.open(Self.inputMonitoringSettingsURL)
    }

    // MARK: Health and sleep/wake

    /// Every 2 s: pick up permission changes, re-enable a disabled tap and
    /// restart the output engine if it died (device changes, errors, sleep).
    private func startHealthChecks() {
        let timer = Timer(timeInterval: Self.healthCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.healthCheck() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func healthCheck() {
        refreshPermissions()
        keyMonitor.ensureEnabled()
        guard isEnabled else { return }
        soundEngine.ensureRunning()
    }

    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWake() }
            }
            wakeObservers.append(observer)
        }
    }

    private func handleWake() {
        // Audio hardware can take a moment to come back after sleep.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.keyMonitor.isActive {
                    self.keyMonitor.ensureEnabled()
                } else {
                    self.keyMonitor.start()
                }
                self.healthCheck()
            }
        }
    }

    // MARK: Pipeline

    /// Runs the output engine only while sounds are on, so a disabled Kliq uses no CPU.
    private func applyEnabledState() {
        if isEnabled {
            soundEngine.start()
        } else {
            soundEngine.stop()
        }
    }

    /// Plays right away: the velocity comes from the force source if it has a
    /// reading, otherwise from the chosen intensity.
    private func handleKeyDown(at keyTime: UInt64, keyCode: UInt16) {
        guard isEnabled else { return }
        let velocity = forceSource?.velocity(forKeyPressAt: keyTime, keyCode: keyCode) ?? intensity.velocity
        play(velocity: velocity, keyCode: keyCode)
    }

    private func handleKeyUp(keyCode: UInt16) {
        guard isEnabled, keyUpSounds else { return }
        soundEngine.playKeyUp(keyCode: keyCode, masterVolume: volume)
    }

    /// Picks up profile folders added, removed or re-imported while Kliq is
    /// running. Called whenever the settings popover or window is shown.
    func rescanProfiles() {
        let profiles = SoundProfile.builtIn + SoundProfile.scanImported()
        if profiles.map(\.displaySignature) != availableProfiles.map(\.displaySignature) {
            availableProfiles = profiles
        }
        if let current = profiles.first(where: { $0 == soundProfile }) {
            if current.contentStamp != soundProfile.contentStamp
                || current.displaySignature != soundProfile.displaySignature {
                soundProfile = current // re-imported or re-tagged; same id, so no preview plays
            }
        } else {
            soundProfile = .default // its folder was deleted
        }
    }

    /// Plays a sample of any profile at the current intensity, without selecting it.
    func preview(_ profile: SoundProfile) {
        guard isEnabled else { return }
        soundEngine.start()
        soundEngine.playPreview(of: profile, velocity: intensity.velocity, masterVolume: volume)
    }

    // MARK: Profiles

    func setType(_ type: ProfileType?, for profile: SoundProfile) {
        do {
            try profile.setType(type)
        } catch {
            errorMessage = "Couldn't save the type: \(error.localizedDescription)"
        }
        rescanProfiles()
    }

    /// Opens (and creates, if needed) the folder imported profiles live in.
    func openProfilesFolder() {
        let folder = SoundProfile.importedProfilesDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func importProfile(from url: URL) {
        guard !isImporting else { return }
        importState = .importing(url.deletingPathExtension().lastPathComponent)
        Task { @MainActor in
            do {
                let folder = try await ProfileImporter.importItem(at: url)
                rescanProfiles()
                if let profile = availableProfiles.first(where: { $0.id == "imported:\(folder)" }) {
                    soundProfile = profile
                    importState = .imported(profile.displayName)
                } else {
                    importState = .imported(folder)
                }
            } catch {
                importState = .failed(error.localizedDescription)
            }
        }
    }

    var isImporting: Bool {
        if case .importing = importState { return true }
        return false
    }

    func removeProfile(_ profile: SoundProfile) {
        do {
            try ProfileImporter.remove(profile)
            importState = .idle
        } catch {
            importState = .failed(error.localizedDescription)
        }
        rescanProfiles()
    }

    // MARK: Launch at login

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        launchAtLoginNeedsApproval = status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    /// Plays one keystroke at the current intensity so the user can hear the profile.
    func previewSound() {
        guard isEnabled else { return }
        soundEngine.start()
        play(velocity: intensity.velocity, keyCode: nil)
    }

    /// `keyCode` picks the key's own sound (nil for a random one); it isn't kept.
    private func play(velocity: Double, keyCode: UInt16?) {
        soundEngine.play(velocity: velocity, keyCode: keyCode, masterVolume: volume)
    }
}
