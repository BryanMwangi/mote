import AppKit
import Combine
import MoteCore
import SwiftUI

/// Every site's boost, kept in one file every window shares (see Boost).
@MainActor
final class Boosts: ObservableObject {
    static let shared = Boosts()
    @Published private(set) var bySite: [String: Boost]
    private let file = JSONFile<[String: Boost]>("boosts.json")

    private init() { bySite = file.load() ?? [:] }

    func boost(for site: String?) -> Boost { site.flatMap { bySite[$0] } ?? Boost() }

    func set(_ boost: Boost, for site: String) {
        bySite[site] = boost.isEmpty ? nil : boost
        file.save(bySite)
    }

    /// A style element at the top of the document with the boost's rules,
    /// replaced in place when it changes.
    nonisolated static func styling(_ sheet: String) -> String {
        let text = (try? JSONEncoder().encode(sheet)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return """
            (() => {
              let style = document.getElementById("mote-boost");
              if (!style) { style = document.createElement("style"); style.id = "mote-boost"; (document.head || document.documentElement).appendChild(style); }
              style.textContent = \(text);
            })()
            """
    }
}

extension Browser {
    /// Boost This Site…: the panel for the site in front.
    func boostSite() {
        guard let site = Address.siteHost(of: active?.address) else { return }
        boosting = site
    }

    /// A boost, kept and shown at once on every tab of its site.
    func setBoost(_ boost: Boost, for site: String) {
        Boosts.shared.set(boost, for: site)
        let sheet = boost.stylesheet
        for tab in Windows.shared.all.flatMap(\.tabs) where Address.siteHost(of: tab.address) == site {
            tab.boostSheet = sheet
            tab.arm(hiding: tab.hiding)
            tab.built?.evaluateInAppWorld(Boosts.styling(sheet))
        }
    }
}

/// The boost editor, as Zen's, in a frosted panel that stays over the page
/// while it changes: a field with two dots, the cast over the page and its
/// links' colour; dark, the finer controls, and off; fonts; size and case;
/// Snap, to pick things off the page; and CSS of your own.
struct BoostEditor: View {
    @ObservedObject var browser: Browser
    let site: String
    @ObservedObject private var boosts = Boosts.shared
    @ObservedObject private var hider: ElementHider

    @State private var tuning = false
    @State private var coding = false

    private static let fonts = ["Georgia", "Helvetica Neue", "Avenir Next", "New York", "Charter", "Menlo", "Verdana", "Futura", "Optima"]
    private static let sizes = [0.9, 1, 1.1, 1.25, 1.5]
    private static let cases: [String?] = [nil, "uppercase", "lowercase", "capitalize"]

    init(browser: Browser, site: String) {
        self.browser = browser
        self.site = site
        hider = browser.elementHider
    }

    private var boost: Boost { boosts.boost(for: site) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Door(icon: "xmark", help: "Close") { browser.boosting = nil }
                Spacer()
                Text(site).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Door(icon: "dice", help: "Shuffle the colours") {
                    change {
                        $0.tint = ThemeColors.hex(at: CGPoint(x: .random(in: -1...1), y: .random(in: -1...1)))
                        $0.accent = ThemeColors.hex(at: CGPoint(x: .random(in: -1...1), y: .random(in: -1...1)))
                    }
                }
            }
            .background(DragHandle())
            if coding { code } else { controls }
        }
        .padding(14)
        .frame(width: 268)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .top) {
                ThemeField(colors: [boost.tint, boost.accent].compactMap { $0 }, harmony: nil, limit: 2, side: 240) { colors, _ in
                    change {
                        $0.tint = colors.first
                        $0.accent = colors.count > 1 ? colors[1] : nil
                    }
                }
                Door(icon: "sparkles", help: "The site's own colours") { change { ($0.tint, $0.accent) = (nil, nil) } }.padding(6)
            }
            HStack(spacing: 8) {
                Tile(symbol: "lightbulb", on: boost.dark, help: "Dark") { change { $0.dark.toggle() } }
                Tile(symbol: "slider.horizontal.3", on: tuning, help: "Brightness, contrast and colour") { tuning.toggle() }
                    .popover(isPresented: $tuning, arrowEdge: .bottom) { finer }
                Tile(symbol: "nosign", on: !boost.enabled, help: boost.enabled ? "Switch the boost off" : "Switch it back on") {
                    change { $0.enabled.toggle() }
                }
            }
            fonts
            HStack(spacing: 8) {
                Tile(title: "Size", value: "\(Int((boost.size * 100).rounded()))%", on: boost.size != 1) {
                    change { $0.size = Self.sizes[((Self.sizes.firstIndex(of: $0.size) ?? 1) + 1) % Self.sizes.count] }
                }
                Tile(title: "Case", value: boost.textCase?.capitalized ?? "None", on: boost.textCase != nil) {
                    change { $0.textCase = Self.cases[((Self.cases.firstIndex(of: $0.textCase) ?? 0) + 1) % Self.cases.count] }
                }
            }
            Tile(title: "Snap", value: "\(hider.hiddenElements(on: site).count)", symbol: "hands.and.sparkles", on: browser.pickingElement)
            {
                browser.toggleHiding()
            }
            .help("Pick things off the page, to dust; ⌘Z puts the last back")
            Tile(title: "Code", value: "{ }", on: !boost.css.isEmpty) { coding = true }
        }
    }

    /// The font grid: each in its own face, then the site's own.
    private var fonts: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                ForEach(Self.fonts, id: \.self) { font in
                    Button {
                        change { $0.font = font }
                    } label: {
                        Text("Aa").font(.custom(font, size: 15)).frame(maxWidth: .infinity, minHeight: 30)
                            .background(
                                boost.font == font ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(font)
                }
            }
            Button("Default") { change { $0.font = nil } }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(boost.font == nil ? Palette.ink : Palette.muted)
        }
        .padding(8)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var finer: some View {
        VStack(alignment: .leading, spacing: 10) {
            slider("Brightness", \.brightness)
            slider("Contrast", \.contrast)
            slider("Colour", \.saturation)
        }
        .padding(14)
        .frame(width: 240)
    }

    private func slider(_ title: String, _ value: WritableKeyPath<Boost, Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            Slider(value: Binding(get: { boost[keyPath: value] }, set: { new in change { $0[keyPath: value] = new } }), in: 0.5...1.5)
        }
    }

    private var code: some View {
        VStack(spacing: 8) {
            TextEditor(text: Binding(get: { boost.css }, set: { css in change { $0.css = css } }))
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 380)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Pill("Back") { coding = false }
                Spacer()
                Pill("Reset Boost") { browser.setBoost(Boost(), for: site) }.disabled(boost.isEmpty)
            }
        }
    }

    private func change(_ edit: (inout Boost) -> Void) {
        var next = boost
        edit(&next)
        browser.setBoost(next, for: site)
    }
}

/// A wide button in the editor: an icon, or a name with its value.
private struct Tile: View {
    var title: String?
    var value: String?
    var symbol: String?
    let on: Bool
    var help = ""
    let act: () -> Void
    @State private var hovering = false

    init(symbol: String, on: Bool, help: String, act: @escaping () -> Void) {
        (self.symbol, self.on, self.help, self.act) = (symbol, on, help, act)
    }

    init(title: String, value: String, symbol: String? = nil, on: Bool, act: @escaping () -> Void) {
        (self.title, self.value, self.symbol, self.on, self.act) = (title, value, symbol, on, act)
    }

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 14, weight: .medium)) }
                if let title { Text(title).font(.system(size: 14, weight: .semibold)) }
                if title != nil { Spacer(minLength: 4) }
                if let value { Text(value).font(.system(size: 13)).foregroundStyle(on ? Palette.ground.opacity(0.8) : Palette.muted) }
            }
            .foregroundStyle(on ? Palette.ground : Palette.ink)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                on ? Palette.ink.opacity(0.85) : hovering ? Palette.hover : Color.black.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
