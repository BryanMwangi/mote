import Combine
import Contacts
import SwiftUI

/// The person's own card in Contacts, offered under a field that asks for a
/// name, an email, a phone or an address (Settings › Privacy › Filling in
/// forms). Nothing goes into the page until they pick it, and never in a
/// private window.
@MainActor
final class ContactFill: ObservableObject {
    static let shared = ContactFill()

    /// Under the focused field of a tab, in points from the page's corner.
    struct Offer: Equatable {
        let tab: Tab.ID
        let spot: CGRect
    }

    @Published private(set) var offer: Offer?
    /// The card, part by part as the forms script names them; read once allowed.
    private(set) var card: [String: String] = [:]
    private var hiding: Task<Void, Never>?

    var name: String { card["name"] ?? [card["given"], card["family"]].compactMap { $0 }.joined(separator: " ") }

    /// Asks macOS for Contacts, then reads the card; whether it may.
    func allow() async -> Bool {
        let store = CNContactStore()
        guard (try? await store.requestAccess(for: .contacts)) == true else { return false }
        read(from: store)
        return !card.isEmpty
    }

    private func read(from store: CNContactStore = CNContactStore()) {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
            CNContactPostalAddressesKey, CNContactOrganizationNameKey,
        ].map { $0 as CNKeyDescriptor }
        guard let me = try? store.unifiedMeContactWithKeys(toFetch: keys) else { return card = [:] }
        var parts: [String: String] = [
            "given": me.givenName, "family": me.familyName, "organization": me.organizationName,
            "email": me.emailAddresses.first.map { $0.value as String } ?? "",
            "tel": me.phoneNumbers.first?.value.stringValue ?? "",
        ]
        if let address = me.postalAddresses.first?.value {
            parts["street"] = address.street.replacingOccurrences(of: "\n", with: ", ")
            parts["city"] = address.city
            parts["region"] = address.state
            parts["postal"] = address.postalCode
            parts["country"] = address.country
        }
        card = parts.filter { !$0.value.isEmpty }
    }

    /// A contact field in `tab` gained focus at `spot`, or lost it (nil).
    func focused(_ tab: Tab, at spot: CGRect?) {
        hiding?.cancel()
        guard let spot else {
            guard offer?.tab == tab.id else { return }
            // A moment, so a click on the offer lands before it goes.
            hiding = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.2))
                guard !Task.isCancelled, self?.offer?.tab == tab.id else { return }
                self?.offer = nil
            }
            return
        }
        if card.isEmpty, CNContactStore.authorizationStatus(for: .contacts) == .authorized { read() }
        offer = card.isEmpty ? nil : Offer(tab: tab.id, spot: spot)
    }

    /// The card into the tab's form, as picked.
    func fill(in tab: Tab, browser: Browser) {
        hiding?.cancel()
        offer = nil
        tab.fillContact(card) { filled in
            browser.announce(filled == 0 ? "No empty fields here take your details" : "Filled \(filled) field\(filled == 1 ? "" : "s")")
        }
    }

    func drop() { offer = nil }
}

/// The offer under a contact field: one row with the card's name.
struct ContactOfferView: View {
    @ObservedObject var fill: ContactFill
    let offer: ContactFill.Offer
    let pick: () -> Void
    @State private var hovering = false

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 22, height: 22)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Fill with your contact details").font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                    Text(fill.name.isEmpty ? "From your card in Contacts" : "\(fill.name) · from Contacts")
                        .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .frame(width: min(360, max(240, offer.spot.width)))
        .background(Palette.ground)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.hairline))
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
        // From the page's top-left corner, just under the field.
        .offset(x: offer.spot.minX, y: offer.spot.maxY + 6)
        .animation(Motion.quick, value: hovering)
    }
}
