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

/// Zen's boost editor, leaner: how bright, how much contrast and colour, a
/// font, and CSS of your own, for one site, shown as they change.
struct BoostPanel: View {
    @ObservedObject var browser: Browser
    let site: String
    @ObservedObject private var boosts = Boosts.shared

    private static let fonts = ["Georgia", "Helvetica Neue", "Avenir Next", "New York", "Charter", "Menlo", "Verdana"]

    private var boost: Boost { boosts.boost(for: site) }

    var body: some View {
        Plate("Boost \(site)", width: 460, close: { browser.boosting = nil }) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    slider("Brightness", \.brightness)
                    slider("Contrast", \.contrast)
                    slider("Colour", \.saturation)
                    HStack {
                        Text("Font").font(.system(size: 12.5)).foregroundStyle(Palette.ink).frame(width: 80, alignment: .leading)
                        Picker(
                            "",
                            selection: Binding(get: { boost.font ?? "" }, set: { font in change { $0.font = font.isEmpty ? nil : font } })
                        ) {
                            Text("The site's own").tag("")
                            ForEach(Self.fonts, id: \.self) { Text($0).font(.custom($0, size: 13)).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    Text("Your own CSS").font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                    TextEditor(text: Binding(get: { boost.css }, set: { css in change { $0.css = css } }))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 110)
                        .scrollContentBackground(.hidden)
                        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(14)
            }
        } foot: {
            HStack {
                Text("Kept for \(site), on every tab of it.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
                Pill("Reset") { browser.setBoost(Boost(), for: site) }.disabled(boost.isEmpty)
            }
        }
    }

    private func slider(_ title: String, _ value: WritableKeyPath<Boost, Double>) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink).frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { boost[keyPath: value] }, set: { new in change { $0[keyPath: value] = new } }), in: 0.5...1.5)
        }
    }

    private func change(_ edit: (inout Boost) -> Void) {
        var next = boost
        edit(&next)
        browser.setBoost(next, for: site)
    }
}
