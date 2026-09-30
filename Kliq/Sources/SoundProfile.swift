import Foundation

/// What kind of switch a profile sounds like. Shown as a tag on its card and
/// stored as `"type"` in the profile's `profile.json`.
enum ProfileType: String, CaseIterable, Identifiable {
    case clicky, tactile, linear, fun

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

/// A folder of keystroke samples: `soft_N.wav`, `medium_N.wav`, `hard_N.wav`
/// and optionally `up_N.wav` (key release), any number of variants each, plus
/// an optional `keymap.json` giving keys their own variant (see `KeyMap`) and
/// an optional `profile.json` (name, type tag, pack credits).
///
/// Built-in profiles live in `Sounds/<id>/` inside the app bundle. Imported
/// ones (see tools/import_mechvibes.py) live in
/// `~/Library/Application Support/Kliq/Profiles/<name>/`.
struct SoundProfile: Identifiable, Hashable {
    let id: String
    let displayName: String
    let summary: String
    let directory: URL
    let isImported: Bool
    /// Changes when the folder's sound files change, so a re-import is picked up.
    let contentStamp: Date
    let type: ProfileType?
    /// For imported packs: who made the original pack and whether it had a license.
    let credit: Credit?

    struct Credit: Hashable {
        let packName: String
        let author: String?
        let source: String
        let licenseFound: Bool
    }

    static func == (lhs: SoundProfile, rhs: SoundProfile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Everything the UI shows, so a rescan can tell whether anything visible changed.
    var displaySignature: String { "\(id)|\(displayName)|\(type?.rawValue ?? "-")" }

    var hasKeyUpSounds: Bool {
        SoundEngine.sampleFiles(in: directory).keys.contains(SoundEngine.keyUpPrefix)
    }

    static let importedProfilesDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Kliq/Profiles", isDirectory: true)
    }()

    // MARK: Built-in

    private static let builtInList: [(id: String, name: String, summary: String)] = [
        ("creamy", "Creamy", "Deep, muted and quiet"),
        ("thock", "Thock", "Solid thock with more attack"),
        ("pop", "Pop", "Soft, round bubble pop"),
        ("clicky", "Clicky", "Crisp click switch"),
        ("typewriter", "Typewriter", "Metallic ring and heavy thud"),
    ]

    /// Built-in profiles. Their bundled `profile.json` can't be edited (that
    /// would break the app's signature), so type changes are kept in UserDefaults.
    static var builtIn: [SoundProfile] {
        let overrides = UserDefaults.standard.dictionary(forKey: typeOverridesKey) as? [String: String] ?? [:]
        return builtInList.map { entry in
            let directory = Bundle.main.resourceURL!.appendingPathComponent("Sounds/\(entry.id)", isDirectory: true)
            let info = ProfileInfo(folder: directory)
            let type = overrides[entry.id].flatMap(ProfileType.init(rawValue:)) ?? info.type
            return SoundProfile(id: entry.id, displayName: entry.name, summary: entry.summary,
                                directory: directory, isImported: false, contentStamp: .distantPast,
                                type: type, credit: nil)
        }
    }

    static var `default`: SoundProfile { builtIn[0] }

    private static let typeOverridesKey = "builtInProfileTypes"

    // MARK: Imported

    /// Scans the imported profiles folder. Folders without any sound files are skipped.
    static func scanImported() -> [SoundProfile] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: importedProfilesDirectory,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])
        else { return [] }
        return folders.compactMap { folder -> SoundProfile? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let files = SoundEngine.sampleFiles(in: folder).values.flatMap(\.values)
            guard !files.isEmpty else { return nil }
            let stamp = (files + [folder.appendingPathComponent(KeyMap.fileName)]).compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }.max() ?? .distantPast
            let info = ProfileInfo(folder: folder)
            return SoundProfile(id: "imported:\(folder.lastPathComponent)",
                                displayName: info.name ?? folder.lastPathComponent,
                                summary: info.summary,
                                directory: folder, isImported: true, contentStamp: stamp,
                                type: info.type, credit: info.credit)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    // MARK: Editing

    /// Changes the type tag: written to `profile.json` for imported profiles,
    /// remembered in UserDefaults for built-in ones.
    func setType(_ newType: ProfileType?) throws {
        guard isImported else {
            var overrides = UserDefaults.standard.dictionary(forKey: Self.typeOverridesKey) as? [String: String] ?? [:]
            overrides[id] = newType?.rawValue
            UserDefaults.standard.set(overrides, forKey: Self.typeOverridesKey)
            return
        }
        let url = directory.appendingPathComponent(ProfileInfo.fileName)
        var json = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        json["type"] = newType?.rawValue
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

/// The optional `profile.json` in a profile folder (written by the importer).
private struct ProfileInfo {
    static let fileName = "profile.json"

    var name: String?
    var summary = "Imported sound pack"
    var type: ProfileType?
    var credit: SoundProfile.Credit?

    init(folder: URL) {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.fileName)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        name = json["name"] as? String
        type = (json["type"] as? String).flatMap { ProfileType(rawValue: $0.lowercased()) }
        if let source = json["source"] as? String {
            summary = "Imported from \(source)"
            if (json["key_up_variants"] as? Int ?? 0) > 0 { summary += ", with key-up sounds" }
            credit = SoundProfile.Credit(packName: json["pack_name"] as? String ?? name ?? folder.lastPathComponent,
                                         author: json["author"] as? String,
                                         source: source,
                                         licenseFound: json["license_found"] as? Bool ?? false)
        }
    }
}
