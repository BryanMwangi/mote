import Combine
import Contacts
import MoteCore
import SwiftUI

/// Contact details for filling in forms (Settings › Privacy › Filling in
/// forms): cards Mote keeps, sealed on the Mac with the passwords' key, and
/// the person's own card in Contacts, which is shown but never changed here.
/// Offered under a field that asks for a name, an email, a phone or an
/// address; nothing goes into the page until one is picked, and never in a
/// private window. A form sent with new details can be offered for keeping.
@MainActor
final class ContactFill: ObservableObject {
    static let shared = ContactFill()

    /// Under the focused field of a tab, in points from the page's corner.
    struct Offer: Equatable {
        let tab: Tab.ID
        let spot: CGRect
    }

    /// Details a page was sent with, offered for keeping.
    struct Keeping: Equatable {
        let card: ContactCard
        let host: String
    }

    @Published private(set) var offer: Offer?
    @Published private(set) var keeping: Keeping?
    /// The cards Mote keeps, most recently used first.
    @Published private(set) var saved: [ContactCard] = []
    /// The person's own card in Contacts, when Mote may read it.
    @Published private(set) var mine: ContactCard?
    /// Settings shows Manage Contacts (asked from under a field).
    @Published var managing = false {
        didSet { if managing { load() } }
    }
    private var hiding: Task<Void, Never>?
    /// The sealed file is read on first need, not at launch: opening it may
    /// have macOS ask for the key.
    private var loaded = false

    private static let file = Storage.file("contacts.vault")
    private static let neverKey = "contacts.never"

    /// Every card to offer: those kept, then the one from Contacts.
    var all: [ContactCard] { saved + [mine].compactMap { $0 } }

    /// The kept cards and the one from Contacts, read once; a no from the
    /// keychain leaves them unread, to try again later.
    func load() {
        guard !loaded else { return }
        if mine == nil, CNContactStore.authorizationStatus(for: .contacts) == .authorized { readMine() }
        guard let cards = SafeStorage.open([ContactCard].self, from: Self.file, named: "contacts") else { return }
        loaded = true
        saved = cards.sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }
    }

    // MARK: - Contacts

    /// Asks macOS for Contacts, then reads the card; whether it may.
    func allow() async -> Bool {
        let store = CNContactStore()
        guard (try? await store.requestAccess(for: .contacts)) == true else { return false }
        readMine(from: store)
        return mine != nil
    }

    private func readMine(from store: CNContactStore = CNContactStore()) {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
            CNContactPostalAddressesKey, CNContactOrganizationNameKey,
        ].map { $0 as CNKeyDescriptor }
        guard let me = try? store.unifiedMeContactWithKeys(toFetch: keys) else { return mine = nil }
        var card = ContactCard()
        card.given = me.givenName
        card.family = me.familyName
        card.organization = me.organizationName
        card.email = me.emailAddresses.first.map { $0.value as String } ?? ""
        card.tel = me.phoneNumbers.first?.value.stringValue ?? ""
        if let address = me.postalAddresses.first?.value {
            card.street = address.street.replacingOccurrences(of: "\n", with: ", ")
            card.city = address.city
            card.region = address.state
            card.postal = address.postalCode
            card.country = address.country
        }
        card.fromContacts = true
        mine = card.name.isEmpty && card.email.isEmpty ? nil : card
    }

    // MARK: - Kept cards

    @discardableResult
    func save(_ card: ContactCard) -> Bool {
        load()
        guard loaded else { return false }
        var card = card
        card.fromContacts = false
        var cards = saved.filter { $0.id != card.id }
        cards.insert(card, at: 0)
        guard SafeStorage.seal(cards, to: Self.file) else { return false }
        saved = cards
        return true
    }

    func remove(_ card: ContactCard) {
        let cards = saved.filter { $0.id != card.id }
        if SafeStorage.seal(cards, to: Self.file) { saved = cards }
    }

    /// A copy of a card (the one from Contacts) to change and keep.
    func duplicate(_ card: ContactCard) -> ContactCard {
        var copy = card
        copy.id = UUID()
        copy.fromContacts = false
        copy.used = nil
        return copy
    }

    private func touch(_ card: ContactCard) {
        guard !card.fromContacts, var kept = saved.first(where: { $0.id == card.id }) else { return }
        kept.used = Date()
        save(kept)
    }

    // MARK: - Under a field

    /// A contact field in `tab` gained focus at `spot`, or lost it (nil).
    func focused(_ tab: Tab, at spot: CGRect?) {
        hiding?.cancel()
        guard let spot else {
            guard offer?.tab == tab.id else { return }
            // A moment, so a click on the list lands before it goes.
            hiding = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.2))
                guard !Task.isCancelled, self?.offer?.tab == tab.id else { return }
                self?.offer = nil
            }
            return
        }
        load()
        offer = all.isEmpty ? nil : Offer(tab: tab.id, spot: spot)
    }

    /// A card into the tab's form, as picked.
    func fill(_ card: ContactCard, in tab: Tab, browser: Browser) {
        hiding?.cancel()
        offer = nil
        touch(card)
        tab.fillContact(card.parts) { filled in
            browser.announce(filled == 0 ? "No empty fields here take these details" : "Filled \(filled) field\(filled == 1 ? "" : "s")")
        }
    }

    func drop() { offer = nil }

    // MARK: - Offering to keep

    /// A page on `host` was sent with these details: offered for keeping
    /// when they're worth it and new, and the site isn't one never to ask.
    func sent(_ parts: [String: String], host: String) {
        let card = ContactCard(parts: parts)
        guard card.worthSaving else { return }
        load()
        guard loaded, !Self.never.contains(host), !all.contains(where: card.isCovered(by:)) else { return }
        keeping = Keeping(card: card, host: host)
    }

    func keep() {
        if let keeping { save(keeping.card) }
        keeping = nil
    }

    func notNow() { keeping = nil }

    func neverHere() {
        if let host = keeping?.host { Self.never.append(host) }
        keeping = nil
    }

    private static var never: [String] {
        get { Storage.settings.stringArray(forKey: neverKey) ?? [] }
        set { Storage.settings.set(newValue, forKey: neverKey) }
    }
}

/// The cards under a contact field: each as its name over a postcode or an
/// email, and at the foot a way to manage them.
struct ContactOfferView: View {
    @ObservedObject var fill: ContactFill
    let offer: ContactFill.Offer
    let pick: (ContactCard) -> Void
    let manage: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(fill.all.prefix(5)) { card in ContactRow(card: card) { pick(card) } }
            Button(action: manage) {
                Label("Manage Contacts…", systemImage: "person.text.rectangle")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.wash.opacity(0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: min(360, max(240, offer.spot.width)))
        .background(Palette.ground)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.hairline))
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
        // From the page's top-left corner, just under the field.
        .offset(x: offer.spot.minX, y: offer.spot.maxY + 6)
    }

    private struct ContactRow: View {
        let card: ContactCard
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Image(systemName: card.fromContacts ? "person.crop.circle" : "person.text.rectangle")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                        .frame(width: 22, height: 22)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.name.isEmpty ? card.email : card.name).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                        Text(card.fromContacts ? "Your card in Contacts" : card.summary).font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(hovering ? Palette.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

/// Settings › Privacy › Saved contacts › Manage: the cards Mote keeps, to
/// add, change or remove; the one from Contacts to copy and change.
struct ContactsSheet: View {
    @ObservedObject var fill = ContactFill.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ContactCard?
    @State private var query = ""

    private var shown: [ContactCard] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !words.isEmpty else { return fill.all }
        return fill.all.filter { [$0.name, $0.email, $0.tel, $0.city, $0.postal].joined(separator: " ").lowercased().contains(words) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Contacts").font(.headline).frame(maxWidth: .infinity)
            if let card = editing {
                ContactEditor(card: card) { kept in
                    if let kept { fill.save(kept) }
                    editing = nil
                }
            } else {
                HStack {
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                    Button("Add") { editing = ContactCard() }
                }
                List(shown) { card in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.name.isEmpty ? "No name" : card.name)
                            Text(card.fromContacts ? "From Contacts" : [card.email, card.tel, card.city].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Spacer()
                        if card.fromContacts {
                            Button("Duplicate and Edit") { editing = fill.duplicate(card) }.controlSize(.small)
                        } else {
                            Button("Edit") { editing = card }.controlSize(.small)
                            Button("Remove", role: .destructive) {
                                guard Dialogs.confirm("Remove \(card.name.isEmpty ? "this contact" : card.name)?", "It's deleted from this Mac.", button: "Remove")
                                else { return }
                                fill.remove(card)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .overlay { if shown.isEmpty { Text(query.isEmpty ? "No contacts yet." : "None match.").foregroundStyle(.secondary) } }
                .frame(minHeight: 220)
                Text("Kept sealed on this Mac. Your card in Contacts is changed in Contacts; duplicate it to keep a version of your own here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 520)
    }
}

/// One card's details, to change and keep, or leave.
private struct ContactEditor: View {
    @State var card: ContactCard
    let done: (ContactCard?) -> Void

    var body: some View {
        Form {
            TextField("First name", text: $card.given)
            TextField("Last name", text: $card.family)
            TextField("Organisation", text: $card.organization)
            TextField("Email", text: $card.email)
            TextField("Phone", text: $card.tel)
            TextField("Street", text: $card.street)
            TextField("City", text: $card.city)
            TextField("State or region", text: $card.region)
            TextField("Postcode", text: $card.postal)
            TextField("Country", text: $card.country)
        }
        .formStyle(.grouped)
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
            Button("Save") { done(card) }.keyboardShortcut(.defaultAction).disabled(card.name.isEmpty && card.email.isEmpty)
        }
    }
}
