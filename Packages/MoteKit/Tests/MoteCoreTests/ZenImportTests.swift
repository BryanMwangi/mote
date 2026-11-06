import Foundation
import Testing

@testable import MoteCore

@Suite("Zen import")
struct ZenImportTests {
    private func tab(
        _ url: String, title: String = "T", essential: Bool = false, pinned: Bool = false, in space: String? = nil,
        container: Int? = nil, label: String? = nil, transient: Bool = false
    ) -> ZenSession.Tab {
        ZenSession.Tab(
            entries: [ZenSession.Entry(url: "https://old.example/"), ZenSession.Entry(url: url, title: title)], index: 2,
            pinned: pinned || essential, essential: essential, workspace: space, label: label, userContextId: container,
            transient: transient)
    }

    @Test("Zen's compressed files decode, and a damaged or foreign one doesn't")
    func mozLZ4() throws {
        let json = Data(#"{"spaces":[],"tabs":[]}"#.utf8) + Data(repeating: 32, count: 300)
        let file = MozLZ4.encode(json)
        #expect(file.prefix(8) == Data("mozLz40\0".utf8))
        #expect(try MozLZ4.decode(file) == json)
        #expect(throws: MozLZ4.Failure.notMozLZ4) { try MozLZ4.decode(Data("{}".utf8)) }
        #expect(throws: MozLZ4.Failure.corrupt) { try MozLZ4.decode(file.prefix(file.count - 4)) }
    }

    @Test("Split views come with their tree, over their space's tab places, as Zen writes them")
    func splits() throws {
        // As Zen 1.17 writes them: tabs named by zenSyncId; the tree's leaves in percent.
        let json = """
            {"spaces":[{"uuid":"w","name":"Work"}],
             "tabs":[{"entries":[{"url":"https://pin.example/"}],"pinned":true,"zenWorkspace":"w","zenSyncId":"p"},
                     {"entries":[{"url":"https://a.example/"}],"zenWorkspace":"w","zenSyncId":"a"},
                     {"entries":[{"url":"https://b.example/"}],"zenWorkspace":"w","zenSyncId":"b"},
                     {"entries":[{"url":"https://c.example/"}],"zenWorkspace":"w","zenSyncId":"c"}],
             "splitViewData":[
               {"groupId":"g1","gridType":"hsep","tabs":["b","a"],
                "layoutTree":{"type":"splitter","direction":"row","children":[
                  {"type":"leaf","tabId":"b","sizeInParent":30},{"type":"leaf","tabId":"a","sizeInParent":70}]}},
               {"groupId":"g2","gridType":"vsep","tabs":["p","c"]},
               {"groupId":"g3","tabs":["gone","c"],
                "layoutTree":{"type":"splitter","direction":"column","children":[
                  {"type":"leaf","tabId":"gone","sizeInParent":50},{"type":"leaf","tabId":"c","sizeInParent":50}]}}]}
            """
        let plan = ZenImportPlan(try ZenSession.read(MozLZ4.encode(Data(json.utf8))))
        let space = try #require(plan.spaces.first)
        #expect(space.tabs.map(\.syncID) == ["p", "a", "b", "c"])
        // Side by side, b (place 2) on the left at 30%.
        #expect(space.splits.count == 2)
        guard case .split(.across, let children) = space.splits[0].root else {
            Issue.record("not across")
            return
        }
        #expect(children.map(\.node) == [.leaf(2), .leaf(1)])
        #expect(abs(children[0].share - 0.3) < 0.001)
        // An older file's group, from its grid: one over another.
        #expect(space.splits[1].ids == [0, 3])
        guard case .split(.down, _) = space.splits[1].root else {
            Issue.record("not down")
            return
        }
        // A group whose other tab didn't come along isn't a split any more.
    }

    @Test("The session file reads with unknown fields and fields of the wrong type")
    func lenientSession() throws {
        let json = """
            {"spaces":[{"uuid":"a","name":"Work","icon":"💼","position":2,"containerTabId":1,"theme":{"type":"gradient"}},
                       {"uuid":"b","name":7,"position":"first"}],
             "tabs":[{"entries":[{"url":"https://a.example/","title":"A"}],"index":1,"pinned":true,"zenEssential":true,
                      "zenWorkspace":"a","attributes":{},"userContextId":1},
                     {"entries":"nonsense","pinned":"yes"}],
             "folders":[],"lastCollected":1}
            """
        let session = try ZenSession.read(MozLZ4.encode(Data(json.utf8)))
        #expect(session.spaces.map(\.uuid) == ["a", "b"])
        #expect(session.spaces[1].name == nil && session.spaces[1].position == nil)
        #expect(session.tabs[0].essential && session.tabs[0].current?.url == "https://a.example/")
        #expect(session.tabs[1].entries.isEmpty && !session.tabs[1].pinned)
    }

    @Test("Spaces keep Zen's order, names and emoji, and a container means data of their own")
    func spaces() {
        let session = ZenSession(
            spaces: [
                .init(uuid: "b", name: "Work", icon: "💼", position: 2, containerTabId: 3),
                .init(uuid: "a", name: " ", icon: "chrome://browser/skin/zen-icons/selectable/star.svg", position: 1),
            ], tabs: [])
        let plan = ZenImportPlan(session, containers: [3: "Job"])
        #expect(plan.spaces.map(\.zenID) == ["a", "b"])
        #expect(plan.spaces.map(\.name) == ["Space 1", "Work"])
        #expect(plan.spaces.map(\.icon) == [nil, "💼"])
        #expect(plan.spaces.map(\.ownData) == [false, true])
    }

    @Test("Tabs go to their space in tiers: essentials, pinned, then the rest")
    func tabs() {
        let session = ZenSession(
            spaces: [.init(uuid: "a", position: 0), .init(uuid: "b", position: 1, containerTabId: 2)],
            tabs: [
                tab("https://loose.example/", in: "b"),
                tab("https://pinned.example/", pinned: true, in: "b", label: "Mine"),
                tab("https://essential.example/", essential: true, container: 2),
                tab("https://first.example/"),
            ])
        let plan = ZenImportPlan(session)
        #expect(plan.spaces[0].tabs.map(\.url.host) == ["first.example"])
        let other = plan.spaces[1].tabs
        #expect(other.map(\.url.host) == ["essential.example", "pinned.example", "loose.example"])
        #expect(other.map(\.tier) == [.essential, .pinned, .loose])
        #expect(other[1].name == "Mine")
        #expect(other[0].title == "T")
    }

    @Test("Empty tabs, Glance previews and pages that aren't on the web stay behind")
    func skipped() {
        let session = ZenSession(
            spaces: [.init(uuid: "a")],
            tabs: [
                tab("about:newtab"), tab("https://glance.example/", transient: true), tab("moz-extension://x/page.html"),
                ZenSession.Tab(entries: []), tab("https://kept.example/"),
            ])
        #expect(ZenImportPlan(session).spaces[0].tabs.map(\.url.host) == ["kept.example"])
    }

    @Test("With no spaces there's nothing to bring")
    func noSpaces() {
        #expect(ZenImportPlan(ZenSession(spaces: [], tabs: [tab("https://a.example/")])).spaces.isEmpty)
    }

    @Test("Profiles come from profiles.ini, the default from installs.ini first")
    func profiles() {
        let ini = """
            [Profile1]
            Name=Default Profile
            IsRelative=1
            Path=Profiles/b.Default Profile
            Default=1

            [Profile0]
            Name=Default (release)
            IsRelative=1
            Path=Profiles/a.Default (release)

            [General]
            StartWithLastProfile=1
            """
        let installs = "[Install6ED35B3CA1B5D3AF]\nDefault=Profiles/a.Default (release)\nLocked=1\n"
        let found = FirefoxProfiles.parse(profiles: ini, installs: installs)
        #expect(found.map(\.name) == ["Default (release)", "Default Profile"])
        #expect(found.map(\.isDefault) == [true, false])
        #expect(FirefoxProfiles.parse(profiles: ini).first?.name == "Default Profile")
    }

    @Test("Emoji are told apart from symbol names, digits and letters")
    func emoji() {
        #expect(Space.isEmoji("💼") && Space.isEmoji("👨‍💻") && Space.isEmoji("❤️"))
        #expect(!Space.isEmoji("briefcase") && !Space.isEmoji("1") && !Space.isEmoji("#") && !Space.isEmoji("A") && !Space.isEmoji(""))
        #expect(Space(id: UUID(), name: "W", icon: "💼").emoji == "💼")
        #expect(Space(id: UUID(), name: "W", icon: "💼").symbol == "briefcase")
    }
}
