import AppKit
import MoteAI
import MoteCore
import SwiftUI

/// First-run setup: a card of two panes, what to do on the left and
/// the thing itself on the right, one step at a time. After the arrival it
/// sits over the arrival's mesh, which takes the space's colours as they're
/// picked, at the size of the window it then shrinks into (see Arrival);
/// without the arrival it shows inside the window.
struct WelcomeCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let finish: () -> Void

    enum Step: CaseIterable { case bring, home, theme, search, apps, ads, layout, ai, links, start }

    @State private var index = 0
    @State private var apps: Set<String> = []
    @State private var isDefault = AppDelegate.isDefault
    @State private var forward = true
    @ObservedObject private var drafts = ThemeDrafts.shared
    private var assistant: Assistant { .shared }

    /// The imported space picked as the first, and whether it brought
    /// colours and essentials: then those steps aren't asked.
    @State private var home: UUID?
    @State private var brought = (colours: false, essentials: false)
    /// The first space has been chosen: once only, even coming back to the step.
    @State private var homed = false

    /// The steps there are: choosing the first space only after an import
    /// brought several, and not those the chosen space already answers.
    private var steps: [Step] {
        Step.allCases.filter {
            switch $0 {
            case .home: browser.importedSpaces.count > 1 || home != nil
            case .theme: !brought.colours
            case .apps: !brought.essentials
            default: true
            }
        }
    }

    private var step: Step { steps[min(index, steps.count - 1)] }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    /// The accent as text: lifted toward white in the dark, so a deep colour still reads.
    private var ink: Color {
        guard scheme == .dark else { return accent }
        if #available(macOS 15, *) { return accent.mix(with: .white, by: 0.5) }
        return accent.opacity(0.9)
    }

    /// The space's first colour, as it's picked; Mote's ink before there is one.
    private var accent: Color { picked ?? Palette.ink }

    private var picked: Color? {
        let theme = drafts.bySpace[browser.spaceID] ?? browser.spaces.first { $0.id == browser.spaceID }?.theme
        return theme?.colors.first.flatMap(Color.init(hex:))
    }

    /// The card is laid out this wide and scaled to fit, so every part of it
    /// grows with the window it's the size of.
    private static let designWidth: CGFloat = 1000

    var body: some View {
        GeometryReader { room in
            let scale = max(room.size.width / Self.designWidth, 0.01)
            HStack(spacing: 0) {
                side.frame(width: 380)
                stage.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.wash)
            }
            .background(Palette.ground)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(width: Self.designWidth, height: room.size.height / scale)
            // Drawn at the scale it's shown at, so text and edges stay sharp.
            .environment(\.displayScale, displayScale * scale)
            .scaleEffect(scale, anchor: .topLeading)
        }
        .shadow(color: .black.opacity(0.18), radius: 40, y: 14)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: index)
    }

    // MARK: - The left pane

    private var side: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                forward = false
                index -= 1
            } label: {
                Label("Back", systemImage: "arrow.left").font(.system(size: 13.5, weight: .medium)).foregroundStyle(ink)
            }
            .buttonStyle(.plain)
            .opacity(index > 0 ? 1 : 0)
            .disabled(index == 0)
            .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.system(size: 34, weight: .bold)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                Text(line).font(.system(size: 14.5)).foregroundStyle(Palette.muted).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(step)
            .transition(.blurReplace)

            Spacer(minLength: 24)

            Button(action: next) {
                Text(step == .start ? "Start Browsing" : "Next")
                    .font(.system(size: 14.5, weight: .semibold))
                    // On a picked colour, white; on Mote's ink, the ground.
                    .foregroundStyle(picked == nil ? Palette.ground : .white)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            Button("Skip for now") { skip() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
                .opacity(optional ? 1 : 0)
                .disabled(!optional)
        }
        .padding(EdgeInsets(top: 44, leading: 44, bottom: 40, trailing: 40))
    }

    private var optional: Bool { [.bring, .home, .apps, .ai].contains(step) }

    /// The imported spaces, to pick the first from.
    private var homes: some View {
        VStack(spacing: 6) {
            ForEach(browser.importedSpaces) { space in
                let on = (home ?? browser.importedSpaces.first?.id) == space.id
                Button {
                    home = space.id
                } label: {
                    HStack(spacing: 12) {
                        Text(space.emoji ?? "").font(.system(size: 18)).frame(width: 24)
                        Text(space.name).font(.system(size: 14, weight: .medium)).foregroundStyle(on ? accent : Palette.ink)
                        Spacer()
                        if let colours = space.theme?.colors.compactMap(Color.init(hex:)), !colours.isEmpty {
                            HStack(spacing: -4) { ForEach(colours.indices, id: \.self) { Circle().fill(colours[$0]).frame(width: 14) } }
                        }
                        Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? accent : Palette.faint)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(on ? Palette.wash : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var title: String {
        switch step {
        case .bring: "Bring your stuff along."
        case .home: "Which space is home?"
        case .theme: "Your space, your colours."
        case .search: "Pick your search engine."
        case .apps: "Choose the apps you use most."
        case .ads: "Browse without the clutter."
        case .layout: "Tabs on top, or down the side."
        case .ai: "Ask anything, your way."
        case .links: "Open links here."
        case .start: "You're all set."
        }
    }

    private var line: String {
        switch step {
        case .bring: "Import your bookmarks, history and passwords from another browser and pick up right where you left off."
        case .home: "Its tabs, essentials and colours become your first space. The others come along as spaces of their own."
        case .theme: "Give each space colours of its own. Watch them fill the screen as you pick."
        case .search: "Where your searches go. You can always change it later."
        case .apps: "They stay at the top of your sidebar as essentials, one click away."
        case .ads: "Mote can block ads and trackers on every site. Any site can be let off later."
        case .layout: "Pick what feels right. ⇧⌘S switches any time."
        case .ai: "Choose who answers when you ask: an app on this Mac, or a service with your key."
        case .links: "A click in Mail, Slack or a PDF goes to your default browser. It can be Mote."
        case .start: "Everything here can be changed in Settings whenever you like."
        }
    }

    // MARK: - The right pane

    private var stage: some View {
        ZStack {
            Group {
                switch step {
                case .bring: framed { ImportForm(browser: browser).frame(width: 400) }
                case .home: framed { homes.frame(width: 360) }
                case .theme: framed { ThemeEditor(browser: browser, space: browser.spaceID, embedded: true) }
                case .search: engines
                case .apps: appGrid
                case .ads: adChoices
                case .layout: TabLayoutChoice(prefs: prefs).frame(maxWidth: 460)
                case .ai: providers
                case .links: defaultBrowser
                case .start: summary
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity), removal: .opacity))
        }
        .padding(40)
    }

    private func framed<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(20)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 18, y: 6)
    }

    private var engines: some View {
        VStack(spacing: 14) {
            ForEach([SearchEngine.google, .duckduckgo, .bing, .kagi], id: \.self) { engine in
                let on = prefs.engine == engine
                Button {
                    prefs.engine = engine
                } label: {
                    HStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Circle()
                                .strokeBorder(on ? accent : Palette.faint, lineWidth: on ? 5 : 1.5)
                                .frame(width: 20, height: 20)
                            Text(engine.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? accent : Palette.ink)
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        SiteMark(host: Self.engineHosts[engine] ?? "", tint: accent, size: 28)
                            .frame(width: 84, height: 72)
                            .background(Palette.wash)
                    }
                    .frame(width: 300, height: 72)
                    .background(Palette.ground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? accent : .clear, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private static let engineHosts: [SearchEngine: String] = [
        .google: "google.com", .duckduckgo: "duckduckgo.com", .bing: "bing.com", .kagi: "kagi.com",
    ]

    private static let appList: [(url: String, name: String, color: String)] = [
        ("https://obsidian.md", "Obsidian", "#7c3aed"), ("https://discord.com", "Discord", "#5865f2"),
        ("https://trello.com", "Trello", "#0052cc"), ("https://slack.com", "Slack", "#e01e5a"),
        ("https://github.com", "GitHub", "#57606a"), ("https://app.tuta.com/", "Tuta", "#c00002"),
        ("https://notion.com", "Notion", "#37352f"), ("https://calendar.google.com", "Calendar", "#4285f4"),
        ("https://figma.com", "Figma", "#f24e1e"),
    ]

    private var appGrid: some View {
        framed {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(104), spacing: 14), count: 3), spacing: 14) {
                ForEach(Self.appList, id: \.url) { app in
                    let on = apps.contains(app.url)
                    Button {
                        if on { apps.remove(app.url) } else { apps.insert(app.url) }
                    } label: {
                        SiteMark(host: URL(string: app.url)?.host() ?? "", tint: Color(hex: app.color) ?? accent, size: 40)
                            .frame(width: 104, height: 104)
                            .background(
                                on ? accent.opacity(0.12) : Palette.wash, in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(on ? accent : .clear, lineWidth: 2)
                            )
                            .overlay(alignment: .topTrailing) {
                                if on {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(accent).padding(8)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .scaleEffect(on ? 0.96 : 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(app.name)
                    .animation(Motion.press, value: on)
                }
            }
        }
    }

    private var adChoices: some View {
        VStack(spacing: 14) {
            choice(
                "Block ads and trackers", "Pages load faster and follow you less", symbol: "shield.lefthalf.filled", on: prefs.shielded
            ) { prefs.shielded = true }
            choice("Show pages as they come", "Nothing blocked", symbol: "shield.slash", on: !prefs.shielded) { prefs.shielded = false }
        }
    }

    private var providers: some View {
        let list = Provider.all.filter { $0.kind != .agent } + Provider.all.filter { $0.kind == .agent }
        return ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                ForEach(list.prefix(8), id: \.id) { provider in
                    choice(
                        provider.name, provider.kind == .cloud ? "With your API key, added in Settings › AI" : "On this Mac",
                        symbol: provider.kind == .cloud ? "cloud" : "desktopcomputer", on: assistant.providerID == provider.id
                    ) { assistant.providerID = provider.id }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 460)
    }

    private var defaultBrowser: some View {
        VStack(spacing: 18) {
            Image(systemName: isDefault ? "checkmark.seal.fill" : "link")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(accent)
                .symbolEffect(.bounce, value: isDefault)
            if isDefault {
                Text("Mote is your default browser").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
            } else {
                Button {
                    AppDelegate.becomeDefault { _ in isDefault = AppDelegate.isDefault }
                } label: {
                    Text("Make Mote the Default").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(picked == nil ? Palette.ground : .white)
                        .padding(.horizontal, 22).frame(height: 42)
                        .background(accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(Motion.settle, value: isDefault)
    }

    private var summary: some View {
        framed {
            VStack(alignment: .leading, spacing: 14) {
                fact("magnifyingglass", "Searching with \(prefs.engine.title)")
                fact(
                    prefs.sidebar ? "sidebar.left" : "rectangle.topthird.inset.filled", prefs.sidebar ? "Tabs down the side" : "Tabs on top"
                )
                fact(
                    prefs.shielded ? "shield.lefthalf.filled" : "shield.slash",
                    prefs.shielded ? "Ads and trackers blocked" : "Nothing blocked")
                fact("sparkles", "Asking \(assistant.provider.name)")
                if browser.essentialCount > 0 { fact("square.grid.3x3", "\(browser.essentialCount) essentials") }
            }
            .frame(width: 300, alignment: .leading)
        }
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(accent).frame(width: 22)
            Text(text).font(.system(size: 14)).foregroundStyle(Palette.ink)
        }
    }

    private func choice(_ title: String, _ detail: String, symbol: String, on: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(on ? accent : Palette.muted).frame(
                    width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Circle().strokeBorder(on ? accent : Palette.faint, lineWidth: on ? 5 : 1.5).frame(width: 20, height: 20)
            }
            .padding(.horizontal, 18)
            .frame(width: 360, height: 66)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? accent : .clear, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Flow

    private func next() {
        if step == .apps { addApps() }
        if step == .home, !homed, let chosen = home ?? browser.importedSpaces.first?.id {
            home = chosen
            homed = true
            Task {
                brought = await browser.makeFirst(chosen)
                advance()
            }
            return
        }
        advance()
    }

    private func advance() {
        guard index + 1 < steps.count else { return finish() }
        forward = true
        index += 1
    }

    private func skip() {
        if step == .apps { apps = [] }
        forward = true
        index += 1
    }

    private func addApps() {
        for app in Self.appList where apps.contains(app.url) {
            guard let url = URL(string: app.url), !browser.tabs.contains(where: { $0.home == url || $0.address == url }) else { continue }
            browser.pin(browser.open(url, foreground: false, atEnd: true))
        }
        apps = []
    }
}

/// A site's own icon (its touch icon, which most sites have), or its initial
/// on its colour while that loads or when there's none.
private struct SiteMark: View {
    let host: String
    let tint: Color
    let size: CGFloat
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                    .transition(.opacity)
            } else {
                Text(host.split(separator: ".").first.map { String($0.prefix(1)).uppercased() } ?? "?")
                    .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.25), value: icon != nil)
        .task(id: host) { icon = await Self.load(host) }
    }

    /// The site's touch icon, else a large favicon from either service that
    /// keeps them; the first that's a real picture of some size.
    private static func load(_ host: String) async -> NSImage? {
        let sources = [
            "https://\(host)/apple-touch-icon.png", "https://www.google.com/s2/favicons?domain=\(host)&sz=128",
            "https://icons.duckduckgo.com/ip3/\(host).ico",
        ]
        for source in sources {
            guard let url = URL(string: source), let (data, response) = try? await URLSession.shared.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data), image.size.width >= 32
            else { continue }
            return image
        }
        return nil
    }
}

/// The welcome inside the window, when there's no arrival (Reduce Motion,
/// or macOS before 15): the same card, over the dimmed window.
struct WelcomeInWindow: View {
    @ObservedObject var browser: Browser

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            WelcomeCard(browser: browser, prefs: browser.prefs) { browser.finishWelcome() }
                .padding(48)
                .frame(maxWidth: 1100, maxHeight: 720)
        }
        .transition(.opacity)
    }
}
