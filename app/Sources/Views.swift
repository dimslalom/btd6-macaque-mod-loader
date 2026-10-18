import AppKit
import SwiftUI

#if !SNAPSHOTS
@main
#endif
struct MacaqueLoaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(width: 640, height: 520)
                .onAppear { model.check() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch model.screen {
                case .checking: ProgressView().controlSize(.large)
                case .intel: IntelScreen()
                case .noGame: NoGameScreen()
                case .rosetta: RosettaScreen()
                case .askAccess(let p): AskAccessScreen(protection: p)
                case .accessDenied(let p): AccessDeniedScreen(protection: p)
                case .install: InstallScreen()
                case .working(let label): WorkingScreen(title: label)
                case .home: HomeScreen()
                case .steam(let signIn): SteamScreen(signIn: signIn)
                case .preparing: PreparingScreen()
                case .playing: PlayingScreen()
                case .failed(let why): FailedScreen(why: why)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: model.screen)
            if MoveToApplications.needed { MoveBanner() }
        }
    }
}

// MARK: - Building blocks

struct Heading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 22, weight: .bold)).multilineTextAlignment(.center)
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
    }
}

struct BigButton: View {
    let title: String
    var symbol: String? = nil
    var color: Color = .accentColor
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label { Text(title) } icon: { if let symbol { Image(systemName: symbol) } }
                .font(.system(size: 15, weight: .semibold))
                .frame(minWidth: 200).padding(.vertical, 10).padding(.horizontal, 18)
        }
        .buttonStyle(.borderedProminent).tint(color).controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }
}

struct Waiting: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(text) }
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Problems

struct IntelScreen: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cpu").font(.system(size: 64)).foregroundStyle(.secondary)
            Heading(title: "Needs an Apple Silicon Mac", subtitle: "M1 or newer. This Mac has an Intel processor.")
        }
    }
}

struct NoGameScreen: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 22) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 60)).foregroundStyle(.tint)
                    .frame(width: 110, height: 110).background(RoundedRectangle(cornerRadius: 26).fill(Color.accentColor.opacity(0.12)))
                Image(systemName: "questionmark.circle.fill").font(.system(size: 30)).foregroundStyle(.white, .orange).offset(x: 8, y: 8)
            }
            Heading(title: "Bloons TD 6 isn’t installed")
            BigButton(title: Engine.steamInstalled ? "Install in Steam" : "Get Steam", symbol: "arrow.down.circle.fill") {
                if Engine.steamInstalled { model.installGameInSteam() }
                else { NSWorkspace.shared.open(URL(string: "https://store.steampowered.com/about/")!) }
            }
            Button("It’s somewhere else…") { model.chooseGameFolder() }.buttonStyle(.link)
            Waiting(text: "Waiting for Bloons TD 6")
        }
    }
}

struct RosettaScreen: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 16) {
                Image(nsImage: model.gameIcon).resizable().frame(width: 72, height: 72)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                Image(systemName: "cpu.fill").font(.system(size: 40)).foregroundStyle(.purple)
                    .frame(width: 72, height: 72).background(RoundedRectangle(cornerRadius: 16).fill(Color.purple.opacity(0.12)))
            }
            Heading(title: "One more piece: Rosetta", subtitle: "The mod loader runs through Apple’s Rosetta. macOS will ask for your password.")
            BigButton(title: "Install Rosetta", symbol: "arrow.down.circle.fill") { model.installRosetta() }
        }
    }
}

// MARK: - Folder access

struct AskAccessScreen: View {
    @EnvironmentObject var model: AppModel
    let protection: Engine.Protection
    var body: some View {
        VStack(spacing: 22) {
            AccessPromptReplica(protection: protection)
            Heading(title: "Click Allow when macOS asks", subtitle: "Your game is in \(protection.folderName), which macOS protects.")
            BigButton(title: "Continue", symbol: "arrow.right") { Task { await model.continueAfterAccess() } }
        }
    }
}

struct AccessDeniedScreen: View {
    @EnvironmentObject var model: AppModel
    let protection: Engine.Protection
    @State private var notInList = false

    var body: some View {
        VStack(spacing: 18) {
            Heading(title: "Let MacaqueLoader open your game folder")
            Picker("", selection: $notInList) {
                Text("Switch it on").tag(false)
                Text("Not in the list?").tag(true)
            }
            .pickerStyle(.segmented).frame(width: 300).labelsHidden()

            HStack(spacing: 18) {
                SettingsReplica(appIcon: NSApp.applicationIconImage,
                                title: notInList ? "Full Disk Access" : "Files & Folders",
                                mode: notInList ? .drag : .toggle)
                if notInList { DraggableAppIcon().transition(.scale.combined(with: .opacity)) }
            }
            .animation(.spring(response: 0.35), value: notInList)

            BigButton(title: "Open System Settings", symbol: "gearshape.fill") {
                NSWorkspace.shared.open(notInList ? Engine.fullDiskAccessURL : protection.settingsURL)
            }
            Waiting(text: "Continues by itself once it works")
        }
    }
}

// MARK: - Install

struct InstallScreen: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: model.gameIcon).resizable().frame(width: 96, height: 96).shadow(radius: 6, y: 3)
            Heading(title: "Mods for Bloons TD 6")
            ComponentTiles(progress: -1)
            BigButton(title: "Install", symbol: "arrow.down.circle.fill") { model.install() }
            if model.untestedGameVersion { UntestedChip() }
        }
    }
}

struct WorkingScreen: View {
    @EnvironmentObject var model: AppModel
    let title: String
    var body: some View {
        VStack(spacing: 24) {
            ComponentTiles(progress: model.progress)
            VStack(spacing: 8) {
                ProgressView(value: model.progress).frame(width: 320)
                Text(model.progressLabel.isEmpty ? title : model.progressLabel).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Home

struct HomeScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmUninstall = false

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                Image(nsImage: model.gameIcon).resizable().frame(width: 84, height: 84).shadow(radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bloons TD 6").font(.system(size: 24, weight: .bold))
                    HStack(spacing: 6) {
                        Pill(text: model.gameVersion, symbol: "tag.fill")
                        Pill(text: "\(model.mods.count) mod\(model.mods.count == 1 ? "" : "s")", symbol: "puzzlepiece.extension.fill")
                        if model.debugMode { Pill(text: "debug", symbol: "ladybug.fill", color: .orange) }
                    }
                }
                Spacer()
                Menu {
                    Button("Repair") { model.repair() }
                    Toggle("Debug logging", isOn: Binding(get: { model.debugMode }, set: { model.setDebug($0) }))
                    Button("Show Logs") { model.showLogs() }
                    Divider()
                    Button("Remove Mods…") { confirmUninstall = true }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30)
            }

            ModGrid(mods: model.mods)
            ModsPathHint()

            if model.untestedGameVersion { UntestedChip() }

            Spacer(minLength: 0)
            VStack(spacing: 8) {
                BigButton(title: "Play", symbol: "play.fill", color: .green) { model.play() }
                HStack(spacing: 16) {
                    Button { model.openModsFolder() } label: { Label("Mods folder", systemImage: "folder") }
                    Button { model.playWithoutMods() } label: { Label("Play without mods", systemImage: "play") }
                }
                .buttonStyle(.link).font(.caption)
            }
        }
        .confirmationDialog("Remove the mod loader?", isPresented: $confirmUninstall) {
            Button("Remove, keep my mods") { model.uninstall(purge: false) }
            Button("Remove everything", role: .destructive) { model.uninstall(purge: true) }
        } message: { Text("The game itself isn’t touched. Steam keeps running it without mods.") }
    }
}

struct Pill: View {
    let text: String
    let symbol: String
    var color: Color = .secondary
    var body: some View {
        Label(text, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.gray.opacity(0.14)))
    }
}

struct ModGrid: View {
    let mods: [Engine.Mod]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                ForEach(mods) { mod in
                    HStack(spacing: 8) {
                        Image(systemName: mod.name == "Btd6ModHelper" ? "wrench.and.screwdriver.fill" : "puzzlepiece.extension.fill")
                            .foregroundStyle(mod.name == "Btd6ModHelper" ? Color.orange : Color.green)
                        Text(mod.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.gray.opacity(0.1)))
                }
            }
        }
        .frame(maxHeight: 150)
    }
}

/// Where more mods come from, shown as the path of in-game buttons.
struct ModsPathHint: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundStyle(.green)
            Text("More mods in the game:").foregroundStyle(.secondary)
            chip("Mods", "puzzlepiece.extension.fill")
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            chip("Browse Mods", "magnifyingglass")
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(Color.gray.opacity(0.35)))
    }
    private func chip(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.callout.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

struct UntestedChip: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Label("BTD6 \(model.gameVersion) is newer than tested. Some mods may need updates.", systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
    }
}

// MARK: - Playing

struct SteamScreen: View {
    @EnvironmentObject var model: AppModel
    let signIn: Bool
    @State private var pulse = false
    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 18) {
                Image(nsImage: Engine.steamIcon).resizable().frame(width: 84, height: 84)
                    .scaleEffect(pulse ? 1.05 : 1)
                Image(systemName: "arrow.right").font(.title2).foregroundStyle(.tertiary)
                Image(nsImage: model.gameIcon).resizable().frame(width: 84, height: 84).opacity(0.5)
            }
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
            Heading(title: signIn ? "Sign in to Steam" : "Starting Steam")
            if signIn {
                Button("Show Steam") { NSWorkspace.shared.open(URL(string: "steam://open/main")!) }.controlSize(.large)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

struct PreparingScreen: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: model.gameIcon).resizable().frame(width: 84, height: 84)
            Heading(title: "Getting mods ready", subtitle: "First launch (and after a game update) takes 1 to 3 minutes.")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.prepSteps) { step in
                    let current = !step.done && model.prepSteps.first(where: { !$0.done })?.id == step.id
                    HStack(spacing: 12) {
                        ZStack {
                            if step.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            else if current { ProgressView().controlSize(.small) }
                            else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                        }
                        .frame(width: 20)
                        Image(systemName: step.symbol).frame(width: 20).foregroundStyle(step.done || current ? .primary : .tertiary)
                        Text(step.title).foregroundStyle(step.done || current ? .primary : .secondary)
                    }
                    .animation(.easeInOut, value: step.done)
                }
            }
            .frame(width: 260, alignment: .leading)
        }
    }
}

struct PlayingScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var pulse = false
    var body: some View {
        VStack(spacing: 22) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: model.gameIcon).resizable().frame(width: 110, height: 110).shadow(radius: 8, y: 4)
                Circle().fill(.green).frame(width: 22, height: 22)
                    .overlay(Circle().stroke(.green.opacity(0.5), lineWidth: 6).scaleEffect(pulse ? 1.8 : 1).opacity(pulse ? 0 : 1))
                    .offset(x: 6, y: 6)
            }
            .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
            Heading(title: "Playing with mods")
            Button("Quit Game") { model.quitGame() }.controlSize(.large)
        }
    }
}

struct FailedScreen: View {
    @EnvironmentObject var model: AppModel
    let why: String
    var body: some View {
        VStack(spacing: 20) {
            switch why {
            case "running":
                Image(nsImage: model.gameIcon).resizable().frame(width: 84, height: 84)
                Heading(title: "Close Bloons TD 6 first")
                HStack { Button("Quit Game") { model.quitGame(); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.check() } }; Button("Try Again") { model.check() } }
                    .controlSize(.large)
            case "steam":
                HStack(spacing: 18) {
                    Image(nsImage: Engine.steamIcon).resizable().frame(width: 84, height: 84)
                    Image(systemName: "arrow.right").font(.title2).foregroundStyle(.tertiary)
                    Image(nsImage: model.gameIcon).resizable().frame(width: 84, height: 84).opacity(0.5)
                }
                Heading(title: "Sign in to Steam, then play again")
                HStack {
                    Button("Show Steam") { NSWorkspace.shared.open(URL(string: "steam://open/main")!) }
                    Button("Play") { model.play() }.buttonStyle(.borderedProminent).tint(.green)
                }
                .controlSize(.large)
            case "crash":
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 56)).foregroundStyle(.orange)
                Heading(title: "The game closed unexpectedly")
                HStack {
                    Button("Debug & Try Again") { model.setDebug(true); model.play() }.buttonStyle(.borderedProminent)
                    Button("Show Logs") { model.showLogs() }
                    Button("Back") { model.check() }
                }
                .controlSize(.large)
            default:
                Image(systemName: "xmark.octagon.fill").font(.system(size: 56)).foregroundStyle(.red)
                Heading(title: "That didn’t work", subtitle: why)
                HStack {
                    Button("Try Again") { model.check() }.buttonStyle(.borderedProminent)
                    Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([Engine.logFile]) }
                }
                .controlSize(.large)
            }
        }
    }
}

// MARK: - Move to Applications

enum MoveToApplications {
    static var needed: Bool {
        #if SNAPSHOTS
        return false
        #endif
        let p = Bundle.main.bundlePath
        return !(p.hasPrefix("/Applications/") || p.hasPrefix(NSHomeDirectory() + "/Applications/"))
    }

    static func move() -> Bool {
        let src = Bundle.main.bundleURL
        let dst = URL(fileURLWithPath: "/Applications").appendingPathComponent(src.lastPathComponent)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dst.path) { try fm.trashItem(at: dst, resultingItemURL: nil) }
            try fm.copyItem(at: src, to: dst)
        } catch { return false }
        Engine.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dst.path])
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/open"); task.arguments = ["-n", dst.path]
        try? task.run()
        if !src.path.contains("/AppTranslocation/") { try? fm.trashItem(at: src, resultingItemURL: nil) }
        NSApp.terminate(nil)
        return true
    }
}

struct MoveBanner: View {
    @State private var failed = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.app.fill").foregroundStyle(.tint)
            Text(failed ? "Drag MacaqueLoader into your Applications folder." : "Keep MacaqueLoader in Applications").font(.callout)
            Spacer()
            if !failed { Button("Move to Applications") { failed = !MoveToApplications.move() }.controlSize(.small) }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.1))
    }
}
