import AppKit
import SwiftUI

// Small replicas of what the user will see or touch, animated to show the action instead of describing it.

/// Loops a 0...1 phase forever (for illustrations).
struct Looping<Content: View>: View {
    var period: Double = 2.4
    @ViewBuilder var content: (Double) -> Content
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            content(t)
        }
    }
}

/// The pointer arrow used in all illustrations.
struct Pointer: View {
    var pressed = false
    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(.black)
            .background(Image(systemName: "cursorarrow").font(.system(size: 24, weight: .bold)).foregroundStyle(.white))
            .scaleEffect(pressed ? 0.85 : 1)
            .shadow(radius: 1)
    }
}

/// Replica of the macOS "would like to access files" prompt (as it looks on current macOS), with the pointer
/// clicking Allow. Title, icon and explanation follow the location, exactly like the real one.
struct AccessPromptReplica: View {
    let protection: Engine.Protection
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Looping(period: 3.2) { t in
            let move = min(1, t / 0.5)
            let pressed = t > 0.55 && t < 0.7
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        ZStack(alignment: .bottomTrailing) {
                            Image(nsImage: protection.icon).resizable().frame(width: 58, height: 58)
                            Image(systemName: "hand.raised.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.blue))
                                .offset(x: 4, y: 3)
                        }
                        Spacer()
                        Text("?").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 24, height: 24).background(Circle().fill(buttonFill))
                    }
                    .padding(.bottom, 14)
                    Text(protection.promptTitle).font(.system(size: 13, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !protection.promptBody.isEmpty {
                        Text(protection.promptBody).font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                    }
                    HStack(spacing: 8) {
                        capsule("Don’t Allow", pressed: false)
                        capsule("Allow", pressed: pressed)
                    }
                    .padding(.top, 16)
                }
                .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 14))
                .frame(width: 262)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(cardFill))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 14, y: 6)

                Pointer(pressed: pressed)
                    .offset(x: 150 + 50 * move, y: 120 + (pointerTargetY - 120) * move)
            }
            .frame(width: 262, alignment: .topLeading)
        }
    }

    // Height of the Allow button's centre, so the pointer lands on it whatever the text length.
    private var pointerTargetY: CGFloat { protection.promptBody.isEmpty ? 150 : 222 }
    private var cardFill: Color { scheme == .dark ? Color(white: 0.11) : Color(white: 0.97) }
    private var buttonFill: Color { scheme == .dark ? Color(white: 0.2) : Color(white: 0.88) }

    private func capsule(_ title: String, pressed: Bool) -> some View {
        Text(title).font(.system(size: 13))
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(Capsule().fill(pressed ? buttonFill.opacity(0.55) : buttonFill))
    }
}

/// A miniature System Settings window. `mode` decides the animation:
/// .toggle: our row exists, the switch gets turned on; .drag: our icon gets dragged into the list.
struct SettingsReplica: View {
    enum Mode { case toggle, drag }
    let appIcon: NSImage
    let title: String
    let mode: Mode

    var body: some View {
        Looping(period: mode == .toggle ? 2.6 : 3.2) { t in
            HStack(spacing: 0) {
                // Sidebar
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 5) { ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 8, height: 8) } }
                        .padding(.bottom, 6)
                    ForEach(0..<6) { i in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 4).fill(i == 4 ? Color.blue : Color.gray.opacity(0.35)).frame(width: 14, height: 14)
                            if i == 4 {
                                Text("Privacy & Security").font(.system(size: 9, weight: .medium)).lineLimit(1)
                            } else {
                                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.25)).frame(width: 60, height: 7)
                            }
                        }
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(i == 4 ? Color.accentColor.opacity(0.18) : .clear))
                    }
                    Spacer()
                }
                .padding(10).frame(width: 130).background(Color.gray.opacity(0.08))

                // Content
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .bold))
                    VStack(spacing: 0) {
                        placeholderRow(width: 70)
                        Divider()
                        if mode == .toggle {
                            ourRow(on: t > 0.45)
                        } else {
                            dragSlot(t: t)
                        }
                        Divider()
                        placeholderRow(width: 55)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
                    if mode == .drag {
                        HStack { Spacer(); Image(systemName: "plus").font(.system(size: 9, weight: .bold)).padding(4)
                            .background(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.4))) }
                    }
                    Spacer()
                }
                .padding(12)
            }
            .frame(width: 360, height: 190)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            .overlay(alignment: .topLeading) {
                if mode == .toggle {
                    let move = min(1, t / 0.4)
                    Pointer(pressed: t > 0.4 && t < 0.52).offset(x: 250 + 70 * move, y: 150 - 72 * move)
                }
            }
        }
    }

    private func placeholderRow(width: CGFloat) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.3)).frame(width: 18, height: 18)
            RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.25)).frame(width: width, height: 7)
            Spacer()
            Capsule().fill(Color.gray.opacity(0.3)).frame(width: 26, height: 15)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func ourRow(on: Bool) -> some View {
        HStack(spacing: 7) {
            Image(nsImage: appIcon).resizable().frame(width: 18, height: 18)
            Text("MacaqueLoader").font(.system(size: 10, weight: .semibold))
            Spacer()
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Color.accentColor : Color.gray.opacity(0.35)).frame(width: 26, height: 15)
                Circle().fill(.white).frame(width: 13, height: 13).padding(1).shadow(radius: 0.5)
            }
            .animation(.easeInOut(duration: 0.2), value: on)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.07))
    }

    private func dragSlot(t: Double) -> some View {
        let arrive = min(1, max(0, (t - 0.1) / 0.45))
        let landed = arrive >= 1
        return ZStack {
            if landed {
                ourRow(on: t > 0.7)
            } else {
                RoundedRectangle(cornerRadius: 5).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(Color.accentColor.opacity(0.6)).frame(height: 26).padding(.horizontal, 6)
                HStack(spacing: 4) {
                    Image(nsImage: appIcon).resizable().frame(width: 22, height: 22)
                    Pointer(pressed: true).scaleEffect(0.8)
                }
                .offset(x: 120 * (1 - arrive), y: 70 * (1 - arrive))
                .opacity(t < 0.1 ? t * 10 : 1)
            }
        }
        .frame(height: 30)
    }
}

/// The real app icon, draggable into System Settings lists.
struct DraggableAppIcon: View {
    @State private var hover = false
    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                .scaleEffect(hover ? 1.06 : 1).animation(.spring(response: 0.3), value: hover)
                .onHover { hover = $0 }
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
            Label("Drag me", systemImage: "hand.draw").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundStyle(.secondary.opacity(0.5)))
        .help("Drag this icon into the list in System Settings")
    }
}

/// What gets installed, as tiles that fill in while installing.
struct ComponentTiles: View {
    var progress: Double            // 0...1, or -1 for idle
    var body: some View {
        HStack(spacing: 14) {
            tile("MelonLoader", "shippingbox.fill", .orange, done: progress >= 0.7)
            Image(systemName: "plus").foregroundStyle(.tertiary)
            tile(".NET", "cpu", .purple, done: progress >= 0.9)
            Image(systemName: "plus").foregroundStyle(.tertiary)
            tile("Mod Helper", "puzzlepiece.extension.fill", .green, done: progress >= 1)
        }
    }

    private func tile(_ name: String, _ symbol: String, _ color: Color, done: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(color)
                    .frame(width: 58, height: 58)
                    .background(RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.13)))
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green).font(.system(size: 18))
                        .offset(x: 5, y: 5).transition(.scale)
                }
            }
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
        .animation(.spring(response: 0.35), value: done)
    }
}
