import Foundation

/// Adds sound profiles from the Settings window.
///
/// Accepts a Mechvibes pack (a folder with `config.json`, or its .zip), which
/// is converted by the bundled `import_mechvibes.py` (needs Python 3 with
/// numpy, and ffmpeg), or a ready-made Kliq profile folder (`soft_N.wav` …),
/// which is copied as is.
enum ProfileImporter {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Imports the item and returns the new profile's folder name.
    static func importItem(at url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try importSync(at: url)
        }.value
    }

    /// Moves an imported profile's folder to the Trash.
    static func remove(_ profile: SoundProfile) throws {
        guard profile.isImported else { throw Failure("Built-in sounds can't be removed.") }
        try FileManager.default.trashItem(at: profile.directory, resultingItemURL: nil)
    }

    // MARK: - Implementation

    private static func importSync(at url: URL) throws -> String {
        let fm = FileManager.default
        var source = url
        var tempDir: URL?
        defer { if let tempDir { try? fm.removeItem(at: tempDir) } }

        if url.pathExtension.lowercased() == "zip" {
            let dir = fm.temporaryDirectory.appendingPathComponent("KliqImport-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            tempDir = dir
            _ = try run("/usr/bin/ditto", ["-x", "-k", url.path, dir.path])
            source = dir
        }

        if let pack = findFolder(in: source, containing: { $0.contains("config.json") }) {
            return try importMechvibes(pack, fallbackName: url.deletingPathExtension().lastPathComponent)
        }
        if let profile = findFolder(in: source, containing: { names in
            names.contains { $0.range(of: #"^(soft|medium|hard)_\d+\.wav$"#, options: .regularExpression) != nil }
        }) {
            return try copyProfile(profile, name: url.deletingPathExtension().lastPathComponent)
        }
        throw Failure("That doesn't look like a sound pack. Choose a Mechvibes pack (a folder or .zip with config.json) or a Kliq profile folder.")
    }

    /// The folder itself or a subfolder up to two levels down whose file names match.
    private static func findFolder(in root: URL, containing matches: ([String]) -> Bool) -> URL? {
        let fm = FileManager.default
        var queue: [(URL, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            if matches(names) { return dir }
            guard depth < 2 else { continue }
            for name in names where !name.hasPrefix(".") && name != "__MACOSX" {
                let child = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                    queue.append((child, depth + 1))
                }
            }
        }
        return nil
    }

    private static func importMechvibes(_ pack: URL, fallbackName: String) throws -> String {
        guard let script = Bundle.main.url(forResource: "import_mechvibes", withExtension: "py") else {
            throw Failure("The importer is missing from Kliq.app. Rebuild Kliq.")
        }
        let output: String
        do {
            output = try run("/usr/bin/env", ["python3", script.path, pack.path])
        } catch let failure as Failure {
            let message = failure.errorDescription ?? ""
            if message.contains("No module named 'numpy'") {
                throw Failure("Importing needs numpy for Python 3. Install it with: pip3 install numpy")
            }
            throw failure
        }
        // The importer prints "Wrote … to:\n  <folder>".
        if let line = output.components(separatedBy: "\n").first(where: { $0.hasPrefix("  /") }) {
            return URL(fileURLWithPath: line.trimmingCharacters(in: .whitespaces)).lastPathComponent
        }
        return fallbackName
    }

    private static func copyProfile(_ folder: URL, name: String) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: SoundProfile.importedProfilesDirectory, withIntermediateDirectories: true)
        let destination = SoundProfile.importedProfilesDirectory.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            throw Failure("A profile named “\(name)” already exists. Remove it first, or rename the folder.")
        }
        try fm.copyItem(at: folder, to: destination)
        return name
    }

    /// Runs a tool with Homebrew's paths available (for python3 and ffmpeg)
    /// and returns its output. Throws with the tool's error text on failure.
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw Failure("Couldn't run \(tool): \(error.localizedDescription)")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stdout = String(decoding: outData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "error: ", with: "")
            let lastLine = stderr.components(separatedBy: "\n").last ?? ""
            throw Failure(lastLine.isEmpty ? "Import failed." : lastLine)
        }
        return stdout
    }
}
