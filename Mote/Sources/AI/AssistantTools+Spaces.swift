import AppKit
import MoteAI
import MoteCore

/// The spaces and the sidebar's foot: listing, making, renaming, icons,
/// colours, order and deleting spaces; and which buttons sit at the foot.
/// Every change names what it changed and how to put it back.
extension AssistantTools {
    private static let spaceSchema = #""space":{"type":"string","description":"A space's id from list_spaces, or its name"}"#

    var spaceTools: [Tool] {
        let object = { (properties: String, required: [String]) in
            "{\"type\":\"object\",\"properties\":{\(properties)}" + (required.isEmpty ? "" : ",\"required\":[\(required.map { "\"\($0)\"" }.joined(separator: ","))]") + "}"
        }
        let icons = Space.icons.prefix(40).map(\.symbol).joined(separator: ", ")
        return [
            Tool(
                name: "list_spaces",
                description: "Every space: id, name, icon, colours, whether it shares sign-ins with the first, how many tabs it has, and which is showing. The space icons at the sidebar's foot.",
                schema: object("", [])),
            Tool(
                name: "new_space",
                description:
                    "Makes a space and shows it. shares_sign_ins (the default) keeps the first space's sign-ins; false gives it website data of its own (for a guest, say). icon: one of \(icons), or an emoji.",
                schema: object(#""name":{"type":"string"},"icon":{"type":"string"},"shares_sign_ins":{"type":"boolean"}"#, ["name"])),
            Tool(name: "rename_space", description: "Renames a space.", schema: object("\(Self.spaceSchema),\"name\":{\"type\":\"string\"}", ["space", "name"])),
            Tool(
                name: "space_icon", description: "Gives a space an icon: one of \(icons), or an emoji.",
                schema: object("\(Self.spaceSchema),\"icon\":{\"type\":\"string\"}", ["space", "icon"])),
            Tool(
                name: "space_theme",
                description:
                    "A space's colours: a preset by number (1 to \(SpaceTheme.presets.count)), colors (one to three \"#rrggbb\"), off; and look: light, dark or auto (Mote's).",
                schema: object(
                    "\(Self.spaceSchema),\"preset\":{\"type\":\"integer\"},\"colors\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"off\":{\"type\":\"boolean\"},\"look\":{\"type\":\"string\",\"enum\":[\"light\",\"dark\",\"auto\"]}",
                    ["space"])),
            Tool(
                name: "order_spaces", description: "Puts the spaces in this order (ids or names; any left out keep their order after).",
                schema: object(#""spaces":{"type":"array","items":{"type":"string"}}"#, ["spaces"])),
            Tool(
                name: "delete_space",
                description:
                    "Deletes a space for good, with its website data if it kept its own. Give move_tabs_to (a space) to keep its tabs; one with tabs isn't deleted otherwise. The first space can't be. Always asks the person.",
                schema: object("\(Self.spaceSchema),\"move_tabs_to\":{\"type\":\"string\"}", ["space"])),
            Tool(
                name: "sidebar_foot",
                description:
                    "The buttons at the sidebar's foot, beside the space icons: lists them (no arguments), or sets them: order (every button wanted, in order), show (add some), hide (take some away). Buttons: \(FootButton.allCases.map(\.rawValue).joined(separator: ", ")).",
                schema: object(
                    #""order":{"type":"array","items":{"type":"string"}},"show":{"type":"array","items":{"type":"string"}},"hide":{"type":"array","items":{"type":"string"}}"#,
                    [])),
        ]
    }

    func runSpaces(_ call: ToolCall) async -> String? {
        let input = call.input
        switch call.name {
        case "list_spaces": return listSpaces()
        case "new_space": return await newSpace(input)
        case "rename_space": return await renameSpace(input)
        case "space_icon": return await spaceIcon(input)
        case "space_theme": return await spaceTheme(input)
        case "order_spaces": return await orderSpaces(input)
        case "delete_space": return await deleteSpace(input)
        case "sidebar_foot": return await sidebarFoot(input)
        default: return nil
        }
    }

    // MARK: -

    private func space(_ text: String?) -> Space? {
        guard let text, !text.isEmpty else { return nil }
        let key = text.lowercased()
        return browser.spaces.first { Self.short($0.id) == key || $0.id.uuidString.lowercased() == key }
            ?? browser.spaces.first { $0.name.localizedCaseInsensitiveCompare(text) == .orderedSame }
    }

    private static func line(_ space: Space) -> String { "“\(space.name)” (\(short(space.id)))" }

    private var noSpace: String { "There's no such space. Spaces: " + browser.spaces.map(Self.line).joined(separator: ", ") + "." }

    /// A space's tabs as lines, and how many are essential or pinned: from a
    /// window showing it, its parked row, or (not loaded) its saved session.
    private func tabs(in space: Space) -> (lines: [String], held: Int) {
        let loaded = Windows.shared.all.first(where: { $0.spaceID == space.id && !$0.isPrivate })?.tabs ?? browser.parked[space.id]?.tabs
        if let loaded {
            let tabs = loaded.filter { !$0.isBlank }
            return (tabs.map { "- " + Self.line($0) }, tabs.filter(\.held).count)
        }
        let saved = Session.read(space: space.id).tabs.filter { !$0.url.isEmpty }
        return (saved.map { "- “\($0.title)” \($0.url)" }, saved.filter { $0.pin != nil || $0.kept == true }.count)
    }

    private func listSpaces() -> String {
        browser.spaces.map { space in
            let all = tabs(in: space)
            let theme = space.theme.map { theme in
                theme.colors.joined(separator: " ") + (theme.scheme.map { ", \($0.rawValue)" } ?? "")
            } ?? "no colours"
            return [
                Self.short(space.id), space.name, "icon \(space.icon ?? "none")", theme,
                space.isFirst ? "the first space" : (space.sharesSignIns == true ? "shares sign-ins" : "its own sign-ins"),
                "\(all.lines.count) tabs (\(all.held) essential or pinned)",
                space.id == browser.spaceID ? "showing" : "",
            ].filter { !$0.isEmpty }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    private func newSpace(_ input: JSON) async -> String {
        guard let name = input["name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "Give it a name." }
        guard await permit(.gentle, "") else { return refused }
        let before = Set(browser.spaces.map(\.id))
        browser.addSpace(named: name, icon: input["icon"]?.string, sharesSignIns: input["shares_sign_ins"]?.bool ?? true)
        guard let made = browser.spaces.first(where: { !before.contains($0.id) }) else { return "It couldn't be made." }
        return "Made the space \(Self.line(made)), showing now." + record("Made the space “\(made.name)”") { [weak browser] in
            guard let browser, let now = browser.spaces.first(where: { $0.id == made.id }) else { return "It's gone already." }
            guard self.tabs(in: now).lines.isEmpty else { return "It has tabs now; delete it with delete_space if it should go." }
            browser.deleteSpace(made.id)
            return "Deleted it again."
        }
    }

    private func renameSpace(_ input: JSON) async -> String {
        guard let found = space(input["space"]?.string) else { return noSpace }
        guard let name = input["name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "Give the new name." }
        guard await permit(.gentle, "") else { return refused }
        let was = found.name
        browser.renameSpace(found.id, to: name)
        return "Renamed “\(was)” to “\(name)” (\(Self.short(found.id)))." + record("Renamed the space “\(was)” to “\(name)”") { [weak browser] in
            browser?.renameSpace(found.id, to: was)
            return "Named “\(was)” again."
        }
    }

    private func spaceIcon(_ input: JSON) async -> String {
        guard let found = space(input["space"]?.string) else { return noSpace }
        guard let icon = input["icon"]?.string?.trimmingCharacters(in: .whitespaces), !icon.isEmpty else { return "Give an icon." }
        let emoji = icon.unicodeScalars.contains { $0.properties.isEmojiPresentation }
        guard emoji || Space.icons.contains(where: { $0.symbol == icon }) || NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil else {
            return "“\(icon)” isn't an icon Mote has; use one of the listed symbols, or an emoji."
        }
        guard await permit(.gentle, "") else { return refused }
        let was = found.icon
        browser.setSpaceIcon(found.id, to: icon)
        return "\(Self.line(found)) has the icon \(icon) now." + record("Gave “\(found.name)” the icon \(icon)") { [weak browser] in
            if let was { browser?.setSpaceIcon(found.id, to: was) }
            return "Its icon is as it was."
        }
    }

    private func spaceTheme(_ input: JSON) async -> String {
        guard let found = space(input["space"]?.string) else { return noSpace }
        var theme = found.theme
        if input["off"]?.bool == true {
            theme = nil
        } else if let number = input["preset"]?.int {
            guard SpaceTheme.presets.indices.contains(number - 1) else { return "Presets go from 1 to \(SpaceTheme.presets.count)." }
            let preset = SpaceTheme.presets[number - 1]
            theme = SpaceTheme(colors: preset.colors, opacity: preset.opacity, grain: 1, scheme: theme?.scheme)
        } else if let colors = input["colors"]?.array.compactMap(\.string), !colors.isEmpty {
            guard colors.allSatisfy({ $0.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil }) else {
                return "Colours are \"#rrggbb\", one to three."
            }
            theme = SpaceTheme(colors: colors, opacity: theme?.opacity ?? 0.45, grain: theme?.grain ?? 1, scheme: theme?.scheme)
        }
        if let look = input["look"]?.string {
            var with = theme ?? SpaceTheme(colors: [])
            with.scheme = look == "light" ? .light : look == "dark" ? .dark : nil
            theme = with.colors.isEmpty && with.scheme == nil ? nil : with
        }
        guard await permit(.gentle, "") else { return refused }
        let was = found.theme
        browser.setSpaceTheme(found.id, to: theme)
        let said = theme.map { "colours \($0.colors.joined(separator: " "))" + ($0.scheme.map { ", \($0.rawValue)" } ?? "") } ?? "no colours"
        return "\(Self.line(found)) has \(said) now." + record("Changed the colours of “\(found.name)”") { [weak browser] in
            browser?.setSpaceTheme(found.id, to: was)
            return "Its colours are as they were."
        }
    }

    private func orderSpaces(_ input: JSON) async -> String {
        let named = input["spaces"]?.array.compactMap { space($0.string) } ?? []
        guard !named.isEmpty else { return noSpace }
        guard await permit(.gentle, "") else { return refused }
        let was = browser.spaces.map(\.id)
        for (index, space) in named.enumerated() { browser.moveSpace(space.id, to: index) }
        return "The spaces are in this order now: " + browser.spaces.map(\.name).joined(separator: ", ") + "."
            + record("Put the spaces in a new order") { [weak browser] in
                for (index, id) in was.enumerated() { browser?.moveSpace(id, to: index) }
                return "They're in their old order."
            }
    }

    private func deleteSpace(_ input: JSON) async -> String {
        guard let found = space(input["space"]?.string) else { return noSpace }
        guard !found.isFirst else { return "The first space can't be deleted; rename it instead." }
        let inside = tabs(in: found).lines
        let target = space(input["move_tabs_to"]?.string)
        if input["move_tabs_to"] != nil, target == nil || target?.id == found.id { return "Say which other space its tabs go to. " + noSpace }
        if !inside.isEmpty, target == nil {
            return "“\(found.name)” has \(inside.count) tabs; give move_tabs_to to keep them, or close them first:\n" + inside.joined(separator: "\n")
        }
        let question =
            "Delete the space “\(found.name)”" + (target.map { ", moving its \(inside.count) tabs to “\($0.name)”" } ?? "")
            + (found.sharesSignIns == true ? "?" : ", with its own sign-ins and website data?") + " This can't be undone."
        guard await permit(.irreversible, question) else { return refused }
        if let target, !inside.isEmpty {
            // Shown, so its tabs move from the row on screen.
            if browser.spaceID != found.id { browser.switchSpace(to: found.id, gliding: false) }
            for tab in browser.tabs where !tab.isBlank { browser.move(tab, toSpace: target.id) }
        }
        browser.deleteSpace(found.id)
        return "Deleted the space “\(found.name)”" + (target.map { "; its tabs went to “\($0.name)”:\n" + inside.joined(separator: "\n") } ?? ".") + "\nThis can't be undone."
    }

    private func sidebarFoot(_ input: JSON) async -> String {
        let parse = { (key: String) -> (found: [FootButton], unknown: [String]) in
            let names = input[key]?.array.compactMap(\.string) ?? []
            let found = names.compactMap { name in
                FootButton.allCases.first { $0.rawValue.lowercased() == name.lowercased().replacingOccurrences(of: " ", with: "") || $0.title.lowercased() == name.lowercased() }
            }
            return (found, names.filter { name in !found.contains { $0.rawValue.lowercased() == name.lowercased() || $0.title.lowercased() == name.lowercased() } })
        }
        let was = prefs.foot
        let listing = { (list: [FootButton]) in list.map(\.title).joined(separator: ", ").ifEmpty("none") }
        let order = parse("order"), show = parse("show"), hide = parse("hide")
        guard !order.found.isEmpty || !show.found.isEmpty || !hide.found.isEmpty else {
            let unknown = order.unknown + show.unknown + hide.unknown
            return (unknown.isEmpty ? "" : "No button is called \(unknown.joined(separator: ", ")). ")
                + "At the foot now: \(listing(was)). Can be added: \(listing(FootButton.allCases.filter { !was.contains($0) }))."
        }
        guard await permit(.gentle, "") else { return refused }
        var next = order.found.isEmpty ? was : order.found
        next += show.found.filter { !next.contains($0) }
        next.removeAll { hide.found.contains($0) }
        prefs.foot = next
        let unknown = order.unknown + show.unknown + hide.unknown
        return "At the foot now: \(listing(next))." + (unknown.isEmpty ? "" : " No button is called \(unknown.joined(separator: ", ")).")
            + record("Changed the sidebar's foot") { [weak prefs = self.prefs] in
                prefs?.foot = was
                return "The foot is as it was."
            }
    }
}
