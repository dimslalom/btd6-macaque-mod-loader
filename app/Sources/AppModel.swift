import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable {
        case checking
        case intel
        case noGame
        case rosetta
        case askAccess(Engine.Protection)        // before the system prompt: show what's coming
        case accessDenied(Engine.Protection)     // prompt was denied: show how to fix it
        case install                             // nothing installed yet
        case working(String)                     // install / repair / uninstall running
        case home
        case steam(signIn: Bool)                 // waiting for Steam to start / for the user to sign in
        case preparing                           // first modded launch or launch after a game update
        case playing
        case failed(String)
    }

    @Published var screen: Screen = .checking
    @Published var game: URL?
    @Published var gameVersion = ""
    @Published var gameIcon = NSImage(named: NSImage.applicationIconName)!
    @Published var mods: [Engine.Mod] = []
    @Published var progress = 0.0
    @Published var progressLabel = ""
    @Published var installedVersion: String?
    @Published var untestedGameVersion = false
    @Published var debugMode = false
    @Published var prepSteps: [PrepStep] = PrepStep.all
    @Published var gameRunning = false

    private var pollTask: Task<Void, Never>?
    private var gamePID: pid_t = 0
    private let defaults = UserDefaults.standard

    // MARK: Checks

    func check() {
        pollTask?.cancel()
        screen = .checking
        Task {
            guard Engine.isAppleSilicon else { screen = .intel; return }
            guard let game = Engine.findGame() else { screen = .noGame; watchForGame(); return }
            self.game = game
            // Nothing inside a protected folder is touched (not even the game's icon) until the user has seen what
            // macOS will ask. macOS asks again for every new build of this app (ad-hoc signature), so remember the
            // grant per build, not once.
            let protection = Engine.protection(of: game)
            if protection != .none, defaults.string(forKey: "accessBuild") != Engine.buildID {
                screen = .askAccess(protection); return
            }
            await continueAfterAccess()
        }
    }

    /// Called after the "macOS will ask" screen, or directly when the folder isn't protected.
    func continueAfterAccess() async {
        guard let game else { return }
        let readable = await Task.detached { Engine.canRead(game) }.value
        guard readable else { screen = .accessDenied(Engine.protection(of: game)); watchForAccess(); return }
        defaults.set(Engine.buildID, forKey: "accessBuild")
        gameIcon = Engine.gameIcon(game)
        guard await Task.detached(operation: { Engine.rosettaInstalled() }).value else { screen = .rosetta; return }
        refresh()
        if !Engine.isInstalled(game) { screen = .install; return }
        if installedVersion != Engine.appVersion, Engine.appVersion != "dev" {
            await runEngine(["install", "--yes", "--game", game.path], label: "Updating mod files"); return
        }
        screen = Engine.gameRunning ? .playing : .home
        if Engine.gameRunning { watchGame() }
    }

    func refresh() {
        guard let game else { return }
        gameVersion = Engine.gameVersion(game)
        mods = Engine.mods(game)
        installedVersion = Engine.installInfo(game)?.values["installer"]
        let known = (try? String(contentsOf: game.appendingPathComponent("_modkit/known-good-versions"), encoding: .utf8)) ?? ""
        untestedGameVersion = !known.isEmpty && !known.split(whereSeparator: \.isWhitespace).contains {
            gameVersion == $0 || gameVersion.hasPrefix($0 + ".")
        }
        debugMode = FileManager.default.fileExists(atPath: game.appendingPathComponent("_modkit/debug").path)
    }

    // MARK: Waiting on the user

    private func watchForGame() {
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Engine.findGame() != nil { check(); return }
            }
        }
    }

    /// Re-checks folder access while the user is in System Settings, and moves on by itself.
    private func watchForAccess() {
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let game else { return }
                if await Task.detached(operation: { Engine.canRead(game) }).value {
                    await continueAfterAccess(); return
                }
            }
        }
    }

    func chooseGameFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the BloonsTD6 folder (the one with BloonsTD6.app inside)"
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.lastPathComponent == "BloonsTD6.app" { url.deleteLastPathComponent() }
        guard Engine.isGameFolder(url) else {
            screen = .failed("That folder doesn't contain BloonsTD6.app."); return
        }
        try? FileManager.default.createDirectory(at: Engine.configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? url.path.write(to: Engine.configFile, atomically: true, encoding: .utf8)
        check()
    }

    func installRosetta() {
        screen = .working("Installing Rosetta")
        Task {
            let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
            _ = await Task.detached { Engine.run("/usr/bin/osascript", ["-e", script]) }.value
            check()
        }
    }

    // MARK: Install / repair / uninstall

    func install() { Task { if let game { await runEngine(["install", "--yes", "--game", game.path], label: "Installing") } } }
    func repair() { Task { if let game { await runEngine(["install", "--yes", "--game", game.path], label: "Repairing") } } }
    func uninstall(purge: Bool) {
        Task {
            guard let game else { return }
            await runEngine(["uninstall", "--yes", "--game", game.path] + (purge ? ["--purge"] : []), label: "Removing mods")
        }
    }

    private func runEngine(_ args: [String], label: String) async {
        if Engine.gameRunning { screen = .failed("running"); return }
        progress = 0; progressLabel = label; screen = .working(label)
        var error: String?
        let status = await Engine.script("install.sh", args) { line in
            if line.hasPrefix("PROGRESS ") {
                let rest = line.dropFirst(9)
                let pct = Double(rest.prefix { $0.isNumber }) ?? 0
                self.progress = pct / 100
                self.progressLabel = String(rest.drop { $0.isNumber }.trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("ERROR ") {
                error = String(line.dropFirst(6).drop { $0 != " " }.dropFirst())
            }
        }
        if status != 0 { screen = .failed(error ?? "Something went wrong. See the log for details."); return }
        check()
    }

    // MARK: Play

    func play() {
        guard let game else { return }
        prepSteps = PrepStep.all
        Task {
            var started = false; var updated = false; var problem: String?
            _ = await Engine.script("payload/launcher.sh", [game.path]) { line in
                let f = line.split(separator: " ")
                switch f.first {
                case "STATE": updated = f.count > 2 && f[2] == "1"
                case "STEAM":
                    if f.count > 1, f[1] == "starting" { self.screen = .steam(signIn: false) }
                    if f.count > 1, f[1] == "sign-in" { self.screen = .steam(signIn: true) }
                case "STARTED", "RUNNING": started = true; if f.count > 1 { self.gamePID = pid_t(f[1]) ?? 0 }
                case "ERROR": problem = String(line.dropFirst(6))
                default: break
                }
            }
            guard started else { screen = .failed(problem ?? "The game didn't start."); return }
            let firstRun = !FileManager.default.fileExists(atPath: game.appendingPathComponent("MelonLoader/Il2CppAssemblies/Assembly-CSharp.dll").path)
            screen = (updated || firstRun) ? .preparing : .playing
            watchGame()
        }
    }

    func playWithoutMods() {
        NSWorkspace.shared.open(URL(string: "steam://rungameid/\(Engine.steamAppID)")!)
    }

    /// Follows MelonLoader's log while the game prepares, and notices when the game quits.
    private func watchGame() {
        pollTask?.cancel()
        let started = Date()
        pollTask = Task {
            guard let game else { return }
            let log = game.appendingPathComponent("MelonLoader/Latest.log")
            var sawWindow = gamePID == 0      // attached to a game that was already running
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let alive = gamePID > 0 ? kill(gamePID, 0) == 0 : Engine.gameRunning
                gameRunning = alive
                if screen == .preparing, let text = try? String(contentsOf: log, encoding: .utf8) {
                    for i in prepSteps.indices where !prepSteps[i].done {
                        if prepSteps[i].markers.contains(where: { text.contains($0) }) { prepSteps[i].done = true }
                    }
                    if prepSteps.allSatisfy(\.done) { sawWindow = true; screen = .playing }
                }
                if !alive {
                    let quick = !sawWindow && Date().timeIntervalSince(started) < 30
                    let launchLog = (try? String(contentsOf: game.appendingPathComponent("_modkit/launch.log"), encoding: .utf8)) ?? ""
                    if quick && !launchLog.contains("SteamAPI_Init(): Loaded") {
                        screen = .failed("steam")             // the game couldn't reach Steam and handed itself to it
                    } else if screen == .preparing || quick {
                        screen = .failed("crash")
                    } else {
                        refresh(); screen = .home
                    }
                    return
                }
            }
        }
    }

    // MARK: Misc

    func setDebug(_ on: Bool) {
        guard let game else { return }
        let flag = game.appendingPathComponent("_modkit/debug")
        if on { FileManager.default.createFile(atPath: flag.path, contents: nil) } else { try? FileManager.default.removeItem(at: flag) }
        debugMode = on
    }

    func openModsFolder() { if let game { NSWorkspace.shared.open(game.appendingPathComponent("Mods")) } }
    func showLogs() {
        if let game { NSWorkspace.shared.activateFileViewerSelecting([game.appendingPathComponent("MelonLoader/Latest.log")]) }
    }
    func installGameInSteam() { NSWorkspace.shared.open(URL(string: "steam://install/\(Engine.steamAppID)")!) }
    func quitGame() { NSRunningApplication.runningApplications(withBundleIdentifier: Engine.gameBundleID).forEach { $0.terminate() } }
}

/// What the first modded launch goes through, matched against MelonLoader's log.
struct PrepStep: Identifiable, Equatable {
    let id: Int
    let title: String
    let symbol: String
    let markers: [String]
    var done = false

    static let all: [PrepStep] = [
        PrepStep(id: 0, title: "Starting MelonLoader", symbol: "power", markers: ["Loading Il2CppAssemblyGenerator", "Assembly Generation"]),
        PrepStep(id: 1, title: "Reading the game", symbol: "magnifyingglass", markers: ["Assembly Generation Successful", "Mods loaded", "Mod loaded"]),
        PrepStep(id: 2, title: "Loading mods", symbol: "puzzlepiece.extension", markers: ["Mods loaded", "Mod loaded"]),
        PrepStep(id: 3, title: "Opening the game", symbol: "gamecontroller", markers: ["Registering ModContent", "scene initialized: TitleScreenUI", "Finished getting mods"]),
    ]
}
