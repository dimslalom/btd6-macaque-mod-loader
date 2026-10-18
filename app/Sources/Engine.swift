import AppKit
import CryptoKit
import Foundation

/// Paths, detection and the bash engine (install.sh, launcher.sh) bundled in Resources/engine.
enum Engine {
    static let steamAppID = "960090"
    static let gameBundleID = "com.ninjakiwi.bloonstd6"
    static let configFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/macaqueloader/game-path")

    static var engineDir: URL { Bundle.main.resourceURL!.appendingPathComponent("engine") }
    /// Identifies this exact build: a hash of the executable. macOS keys folder permissions on the code signature,
    /// which for an ad-hoc-signed app changes with every build, so a new build means macOS asks again.
    static let buildID: String = {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url) else { return appVersion }
        return appVersion + "-" + SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }()

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    // MARK: Mac

    static var isAppleSilicon: Bool {
        var sysinfo = utsname(); uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        if machine == "arm64" { return true }
        // A translated (Rosetta) process reports x86_64; ask the kernel.
        var translated: Int32 = 0; var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
    }

    static func rosettaInstalled() -> Bool {
        run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]) == 0
    }

    // MARK: Game location

    /// Saved game folder, else the first Steam library that has BTD6.
    static func findGame() -> URL? {
        if let saved = try? String(contentsOf: configFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty, isGameFolder(URL(fileURLWithPath: saved)) {
            return URL(fileURLWithPath: saved)
        }
        for lib in steamLibraries() {
            let candidate = lib.appendingPathComponent("steamapps/common/BloonsTD6")
            if isGameFolder(candidate) { return candidate }
        }
        return nil
    }

    static func steamLibraries() -> [URL] {
        let steam = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        var libs = [steam]
        if let vdf = try? String(contentsOf: steam.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8) {
            for line in vdf.split(separator: "\n") {
                let parts = line.split(separator: "\"", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if parts.count == 2, parts[0] == "path" { libs.append(URL(fileURLWithPath: parts[1].replacingOccurrences(of: "\\\\", with: "\\"))) }
            }
        }
        return libs
    }

    static var steamIcon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam") {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil) ?? NSImage()
    }

    static var steamInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam") != nil
    }

    /// Checks existence only (stat), which works even where macOS privacy protection blocks reading.
    static func isGameFolder(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("BloonsTD6.app/Contents/MacOS").path)
    }

    // MARK: Privacy protection (TCC)

    enum Protection: Equatable {
        case none, documents, desktop, downloads, removable, iCloud
        var folderName: String {
            switch self {
            case .none: return ""
            case .documents: return "Documents"
            case .desktop: return "Desktop"
            case .downloads: return "Downloads"
            case .removable: return "external drive"
            case .iCloud: return "iCloud Drive"
            }
        }
        /// The prompt's title, worded the way macOS words it for each location.
        var promptTitle: String {
            switch self {
            case .removable: return "“MacaqueLoader” would like to access files on a removable volume."
            case .iCloud: return "“MacaqueLoader” would like to access files in iCloud Drive."
            default: return "“MacaqueLoader” would like to access files in your \(folderName) folder."
            }
        }
        /// The explanation macOS shows under the title: our own usage description from Info.plist.
        var promptBody: String {
            let key: String
            switch self {
            case .documents: key = "NSDocumentsFolderUsageDescription"
            case .desktop: key = "NSDesktopFolderUsageDescription"
            case .downloads: key = "NSDownloadsFolderUsageDescription"
            case .removable: key = "NSRemovableVolumesUsageDescription"
            case .iCloud, .none: return ""
            }
            #if SNAPSHOTS
            return NSDictionary(contentsOfFile: "app/Info.plist")?[key] as? String ?? ""   // harness isn't a bundle
            #else
            return Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
            #endif
        }
        /// The folder icon macOS uses in the prompt.
        var icon: NSImage {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path: String
            switch self {
            case .documents: path = home + "/Documents"
            case .desktop: path = home + "/Desktop"
            case .downloads: path = home + "/Downloads"
            case .iCloud: path = home + "/Library/Mobile Documents/com~apple~CloudDocs"
            case .removable: return NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil) ?? NSImage()
            case .none: path = home
            }
            return NSWorkspace.shared.icon(forFile: path)
        }
        /// System Settings anchor for the row that controls this access.
        var settingsURL: URL {
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
        }
    }

    static func protection(of url: URL) -> Protection {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.standardizedFileURL.path
        if p.hasPrefix(home + "/Documents/") { return .documents }
        if p.hasPrefix(home + "/Desktop/") { return .desktop }
        if p.hasPrefix(home + "/Downloads/") { return .downloads }
        if p.hasPrefix(home + "/Library/Mobile Documents/") { return .iCloud }
        if p.hasPrefix("/Volumes/") { return .removable }
        return .none
    }

    /// Reading the folder is what macOS gates. The first attempt shows the system prompt (blocking until answered).
    static func canRead(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    // MARK: Install state

    struct InstallInfo { var values: [String: String] }

    static func installInfo(_ game: URL) -> InstallInfo? {
        guard let text = try? String(contentsOf: game.appendingPathComponent("_modkit/install-info.txt"), encoding: .utf8) else { return nil }
        var v: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { v[kv[0]] = kv[1] }
        }
        return InstallInfo(values: v)
    }

    static func isInstalled(_ game: URL) -> Bool {
        let fm = FileManager.default
        return ["melonfix.dylib", "MelonLoader.Bootstrap.dylib", "MelonLoader/net6/MelonLoader.dll",
                "dotnet/dotnet", "Plugins/MelonMacFixes.dll", "_modkit/cpp2il-wrapper.sh"]
            .allSatisfy { fm.fileExists(atPath: game.appendingPathComponent($0).path) }
    }

    static func gameVersion(_ game: URL) -> String {
        let plist = game.appendingPathComponent("BloonsTD6.app/Contents/Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    static func gameIcon(_ game: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: game.appendingPathComponent("BloonsTD6.app").path)
    }

    struct Mod: Identifiable, Hashable { var id: String { file }; let file: String; var name: String { (file as NSString).deletingPathExtension } }

    static func mods(_ game: URL) -> [Mod] {
        let dir = game.appendingPathComponent("Mods")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.lowercased().hasSuffix(".dll") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { Mod(file: $0) }
    }

    static var gameRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: gameBundleID).isEmpty
    }

    // MARK: Running the engine

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }

    /// Runs a bundled script, calling `onLine` on the main actor for each output line, in order. Returns the exit status.
    static func script(_ name: String, _ args: [String], onLine: @escaping @MainActor (String) -> Void) async -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [engineDir.appendingPathComponent(name).path] + args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return -1 }
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines { await onLine(line) }
        } catch {}
        while p.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
        return p.terminationStatus
    }

    static let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacaqueLoader.log")
}
