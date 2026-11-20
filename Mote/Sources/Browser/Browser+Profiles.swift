import AppKit
import MoteCore

/// Profiles as containers in one Mote: a space's tabs live in its profile
/// (its sign-ins and history), and a tab can live in another (Profiles.store).
extension Browser {
    /// The space a tab is in: the one showing, or a parked one.
    func home(of tab: Tab) -> UUID {
        if tabs.contains(where: { $0 === tab }) { return spaceID }
        return parked.first { $0.value.tabs.contains { $0 === tab } }?.key ?? spaceID
    }

    /// A new tab in a profile ("" the default), in front, the field ready.
    func openTab(inProfile profile: String) {
        let tab = Tab(configuration: Web.configuration(profile: profile))
        prepare(tab)
        insert(tab, at: placeForNew())
        bringForward(tab)
        field.askFocus()
        announce("A tab in \(Profiles.shared.name(of: profile.isEmpty ? nil : profile))")
    }

    /// Opens `tab`'s page again in another profile ("" the default), in its
    /// place: signed in only as that profile is, its back history left behind.
    func move(_ tab: Tab, toProfile profile: String) {
        guard !tab.shy, (tab.profile ?? "") != profile, let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let moved = Tab(configuration: Web.configuration(profile: profile))
        prepare(moved)
        if let url = tab.pending ?? tab.address { moved.restore(url: url, title: tab.title, name: tab.name) }
        (moved.pin, moved.kept, moved.folder, moved.home) = (tab.pin, tab.kept, tab.folder, tab.home)
        tab.handChat(to: moved)
        let front = tab.id == activeID
        reorder { $0.insert(moved, at: index) }
        if front { select(moved) }
        close(tab)
        writeSession(now: true)
        announce("In \(Profiles.shared.name(of: profile.isEmpty ? nil : profile)) now")
    }

    /// A space's profile (nil the default). Its tabs open again in it: a
    /// page's sign-ins are its store's, which a tab can't change.
    func setProfile(_ profile: String?, ofSpace id: UUID) {
        guard spaces.first(where: { $0.id == id })?.profile != profile else { return }
        var list = SpaceList(saved: spaces)
        list.edit(id) { $0.profile = profile }
        spaces = list.spaces
        Spaces.write(spaces)
        for other in Windows.shared.all where other !== self { other.spaces = spaces }
        let name = Profiles.shared.name(of: profile)
        if id == spaceID {
            for tab in tabs where tab.profileOverride(in: id) != nil { move(tab, toProfile: profile ?? "") }
        } else if parked[id] != nil {
            // Rebuilt from its session, in the new store.
            let row = parked[id]
            if let row { writeSession(now: true, space: id, tabs: row.tabs, active: row.active) }
            row?.tabs.forEach { $0.close() }
            parked[id] = loadRow(id)
        }
        announce("“\(spaces.first { $0.id == id }?.name ?? "")” lives in \(name)")
    }
}
