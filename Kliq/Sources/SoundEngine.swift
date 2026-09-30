import AVFoundation
import Darwin

/// `keymap.json` in a profile folder: macOS virtual keycode → variant number N.
/// "down" entries select `soft_N`/`medium_N`/`hard_N.wav`, "up" entries `up_N.wav`.
/// Written by tools/import_mechvibes.py from the pack's own key mapping.
struct KeyMap {
    static let fileName = "keymap.json"

    var down: [UInt16: Int] = [:]
    var up: [UInt16: Int] = [:]

    init(directory: URL) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.fileName)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        down = Self.parse(json["down"])
        up = Self.parse(json["up"])
    }

    private static func parse(_ value: Any?) -> [UInt16: Int] {
        guard let entries = value as? [String: Any] else { return [:] }
        var map: [UInt16: Int] = [:]
        for (key, number) in entries {
            if let code = UInt16(key), let n = number as? Int { map[code] = n }
        }
        return map
    }
}

/// Plays the keystroke samples through a pool of always-running player nodes
/// on a dedicated output engine. Call from the main thread.
final class SoundEngine {
    enum Layer: String, CaseIterable {
        case soft, medium, hard

        init(velocity: Double) {
            if velocity < 0.34 {
                self = .soft
            } else if velocity < 0.67 {
                self = .medium
            } else {
                self = .hard
            }
        }
    }

    /// One key sound in up to three velocity layers (`soft_N`, `medium_N`, `hard_N`).
    private struct Variant {
        var layers: [Layer: AVAudioPCMBuffer] = [:]

        /// The requested layer, or the closest one this variant has.
        func buffer(for layer: Layer) -> AVAudioPCMBuffer? {
            let order: [Layer]
            switch layer {
            case .soft: order = [.soft, .medium, .hard]
            case .medium: order = [.medium, .hard, .soft]
            case .hard: order = [.hard, .medium, .soft]
            }
            return order.lazy.compactMap { self.layers[$0] }.first
        }
    }

    /// Everything loaded from one profile folder.
    private struct Sounds {
        var variants: [Variant] = []
        var up: [AVAudioPCMBuffer] = []
        /// macOS keycode → index into `variants` / `up`.
        var keyMap: [UInt16: Int] = [:]
        var upKeyMap: [UInt16: Int] = [:]
        /// Index of the variant with the most energy, used for space and return
        /// when the profile has no sound of its own for them.
        var heaviest: Int?
        var format: AVAudioFormat?
    }

    private static let poolSize = 12
    static let keyUpPrefix = "up"
    /// Key-up sounds play this much quieter than a medium key press.
    private static let keyUpLevel = 0.45
    /// Small random pitch and level changes so repeats of one key don't sound identical.
    private static let pitchVariation: ClosedRange<Float> = 0.985...1.015
    private static let volumeVariation: ClosedRange<Float> = 0.95...1.05
    /// Space, Return and keypad Enter.
    private static let heavyKeys: Set<UInt16> = [49, 36, 76]

    /// Called after the engine had to be rebuilt or failed to start.
    var onError: ((String?) -> Void)?

    private var engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    /// One varispeed per player, between it and the mixer, for pitch variation.
    private var varispeeds: [AVAudioUnitVarispeed] = []
    private var sounds = Sounds()
    private var previewCache: (key: String, buffer: AVAudioPCMBuffer)?
    private var format: AVAudioFormat?
    private(set) var profile: SoundProfile
    private var nextPlayer = 0
    private var configObserver: NSObjectProtocol?
    private var wantsRunning = false
    private var restartPending = false

    var isRunning: Bool { engine.isRunning }

    var hasSounds: Bool { format != nil }

    init(profile: SoundProfile) {
        self.profile = profile
        sounds = Self.loadSounds(profile: profile)
        format = sounds.format
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
    }

    // MARK: Loading

    var hasKeyUpSounds: Bool { !sounds.up.isEmpty }

    /// Switches to another set of samples (or reloads the current one when its
    /// files changed). Takes effect on the next key press.
    func setProfile(_ newProfile: SoundProfile) {
        guard newProfile != profile || newProfile.contentStamp != profile.contentStamp else { return }
        let newSounds = Self.loadSounds(profile: newProfile)
        guard let newFormat = newSounds.format, !newSounds.variants.isEmpty else {
            onError?("Couldn't load the \(newProfile.displayName) sounds.")
            return
        }
        profile = newProfile
        sounds = newSounds
        if newFormat != format {
            // Players are connected with the old format; reconnect them.
            format = newFormat
            if wantsRunning {
                stop()
                start()
            }
        }
    }

    /// Sample files in a profile folder grouped by prefix ("soft", "medium",
    /// "hard", "up"), each keyed by variant number.
    static func sampleFiles(in directory: URL) -> [String: [Int: URL]] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let prefixes = Set(Layer.allCases.map(\.rawValue) + [keyUpPrefix])
        var files: [String: [Int: URL]] = [:]
        for name in names where name.lowercased().hasSuffix(".wav") {
            let parts = name.dropLast(4).split(separator: "_")
            guard parts.count == 2, prefixes.contains(String(parts[0])), let n = Int(parts[1]) else { continue }
            files[String(parts[0]), default: [:]][n] = directory.appendingPathComponent(name)
        }
        return files
    }

    private static func loadSounds(profile: SoundProfile) -> Sounds {
        var sounds = Sounds()
        let files = sampleFiles(in: profile.directory)
        if files.isEmpty {
            NSLog("Kliq: no sounds in \(profile.directory.path)")
        }

        func load(_ url: URL) -> AVAudioPCMBuffer? {
            do {
                let file = try AVAudioFile(forReading: url)
                let fileFormat = file.processingFormat
                if let format = sounds.format, fileFormat != format {
                    NSLog("Kliq: skipping \(url.lastPathComponent), format \(fileFormat) doesn't match \(format)")
                    return nil
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length))
                else { return nil }
                try file.read(into: buffer)
                sounds.format = sounds.format ?? fileFormat
                return buffer
            } catch {
                NSLog("Kliq: couldn't load \(url.lastPathComponent): \(error)")
                return nil
            }
        }

        // Variants in order of their number N; keep the N → index mapping for the key map.
        let numbers = Set(Layer.allCases.flatMap { files[$0.rawValue].map { Array($0.keys) } ?? [] }).sorted()
        var indexByNumber: [Int: Int] = [:]
        for n in numbers {
            var variant = Variant()
            for layer in Layer.allCases {
                if let url = files[layer.rawValue]?[n], let buffer = load(url) {
                    variant.layers[layer] = buffer
                }
            }
            guard !variant.layers.isEmpty else { continue }
            indexByNumber[n] = sounds.variants.count
            sounds.variants.append(variant)
        }

        var upIndexByNumber: [Int: Int] = [:]
        for (n, url) in (files[keyUpPrefix] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let buffer = load(url) else { continue }
            upIndexByNumber[n] = sounds.up.count
            sounds.up.append(buffer)
        }

        let keyMap = KeyMap(directory: profile.directory)
        sounds.keyMap = keyMap.down.compactMapValues { indexByNumber[$0] }
        sounds.upKeyMap = keyMap.up.compactMapValues { upIndexByNumber[$0] }
        sounds.heaviest = sounds.variants.indices.max { energy(of: sounds.variants[$0]) < energy(of: sounds.variants[$1]) }
        return sounds
    }

    /// Total signal energy of a variant's loudest layer; longer, louder, fuller sounds score higher.
    private static func energy(of variant: Variant) -> Float {
        guard let buffer = variant.buffer(for: .hard), let channel = buffer.floatChannelData?[0] else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
        return sum
    }

    /// The variant for a key: the profile's own mapping first, then the heaviest
    /// sound for space/return, then `keyCode % count` so every key is consistent.
    /// With no key code (previews), a random variant.
    func variantIndex(for keyCode: UInt16?) -> Int? {
        let count = sounds.variants.count
        guard count > 0 else { return nil }
        guard let keyCode else { return Int.random(in: 0..<count) }
        if let mapped = sounds.keyMap[keyCode] { return mapped }
        if Self.heavyKeys.contains(keyCode), let heaviest = sounds.heaviest { return heaviest }
        return Int(keyCode) % count
    }

    // MARK: Engine lifecycle

    @discardableResult
    func start() -> Bool {
        wantsRunning = true
        guard let format else {
            onError?("No sound files could be loaded.")
            return false
        }
        if engine.isRunning { return true }
        Log.output.info("Starting output engine")

        if players.isEmpty {
            for _ in 0..<Self.poolSize {
                let player = AVAudioPlayerNode()
                let varispeed = AVAudioUnitVarispeed()
                engine.attach(player)
                engine.attach(varispeed)
                players.append(player)
                varispeeds.append(varispeed)
            }
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                self?.handleConfigurationChange()
            }
        }

        let mixer = engine.mainMixerNode
        for (player, varispeed) in zip(players, varispeeds) {
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(varispeed)
            engine.connect(player, to: varispeed, format: format)
            engine.connect(varispeed, to: mixer, format: format)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            Log.output.error("Output engine failed to start: \(error.localizedDescription, privacy: .public)")
            onError?("Couldn't start audio output: \(error.localizedDescription)")
            return false
        }
        for player in players { player.play() }
        Log.output.info("Output engine started")
        onError?(nil)
        return true
    }

    func stop() {
        guard wantsRunning || engine.isRunning else { return }
        Log.output.info("Stopping output engine")
        wantsRunning = false
        for player in players { player.stop() }
        engine.stop()
    }

    /// Output device changed (headphones, sample rate, etc.). The engine has
    /// already stopped itself; reconnect and restart.
    ///
    /// Bursts of notifications are coalesced into one restart, and a change that
    /// leaves the engine running needs no action.
    private func handleConfigurationChange() {
        let running = engine.isRunning
        Log.output.notice("Configuration change (running: \(running))")
        guard wantsRunning, !restartPending, !running else { return }
        Log.output.notice("Restarting output engine in 0.2 s")
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            guard self.wantsRunning, !self.engine.isRunning else { return }
            for player in self.players { player.stop() }
            self.start()
        }
    }

    /// Restarts the engine if it should be running but isn't (wake from sleep, failed restart).
    func ensureRunning() {
        guard wantsRunning, !restartPending, !engine.isRunning else { return }
        Log.output.notice("Watchdog: output engine not running, restarting")
        start()
    }

    // MARK: Playback

    /// Plays one keystroke. `keyCode` only picks which sound plays and is never
    /// stored. Returns the host time the sound was scheduled, or nil if nothing played.
    @discardableResult
    func play(velocity: Double, keyCode: UInt16?, masterVolume: Double) -> UInt64? {
        guard engine.isRunning, !players.isEmpty,
              let index = variantIndex(for: keyCode),
              let buffer = sounds.variants[index].buffer(for: Layer(velocity: velocity))
        else { return nil }
        let v = min(max(velocity, 0), 1)
        return schedule(buffer, volume: (0.35 + 0.65 * v) * masterVolume)
    }

    /// Plays one sample of any profile, without switching to it (for the
    /// preview buttons on profile cards). Uses the variant the A key would get.
    func playPreview(of other: SoundProfile, velocity: Double, masterVolume: Double) {
        guard other != profile else {
            play(velocity: velocity, keyCode: 0, masterVolume: masterVolume)
            return
        }
        guard engine.isRunning, !players.isEmpty else { return }
        let layer = Layer(velocity: velocity)
        let key = "\(other.id)|\(layer.rawValue)|\(other.contentStamp.timeIntervalSince1970)"
        if previewCache?.key != key {
            let files = Self.sampleFiles(in: other.directory)
            let layerFiles = files[layer.rawValue] ?? files[Layer.medium.rawValue] ?? files.values.first ?? [:]
            let number = KeyMap(directory: other.directory).down[0].flatMap { layerFiles[$0] != nil ? $0 : nil }
                ?? layerFiles.keys.min()
            guard let number, let url = layerFiles[number],
                  let file = try? AVAudioFile(forReading: url), file.processingFormat == format,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil
            else {
                NSLog("Kliq: couldn't load a preview of \(other.displayName)")
                return
            }
            previewCache = (key, buffer)
        }
        guard let buffer = previewCache?.buffer else { return }
        let v = min(max(velocity, 0), 1)
        _ = schedule(buffer, volume: (0.35 + 0.65 * v) * masterVolume)
    }

    /// Plays one key-release sound, quietly. Returns the scheduled host time, or nil.
    @discardableResult
    func playKeyUp(keyCode: UInt16, masterVolume: Double) -> UInt64? {
        let count = sounds.up.count
        guard engine.isRunning, !players.isEmpty, count > 0 else { return nil }
        let index = sounds.upKeyMap[keyCode] ?? Int(keyCode) % count
        return schedule(sounds.up[index], volume: Self.keyUpLevel * masterVolume)
    }

    /// Plays a buffer on the next player with a slight random pitch and level change.
    private func schedule(_ buffer: AVAudioPCMBuffer, volume: Double) -> UInt64 {
        let i = nextPlayer
        nextPlayer = (nextPlayer + 1) % players.count
        let player = players[i]
        varispeeds[i].rate = Float.random(in: Self.pitchVariation)
        player.volume = Float(volume) * Float.random(in: Self.volumeVariation)
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
        return mach_absolute_time()
    }
}
