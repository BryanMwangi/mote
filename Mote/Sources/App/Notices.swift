import Combine
import MoteCore
import SwiftUI

/// What rises from the bottom of the window: a short message, the camera
/// and microphone question, the offer to save a password, the Web Store's
/// "Add to Mote", and the reminder while picking things to hide.
struct Notices: View {
    @ObservedObject var browser: Browser

    var body: some View {
        VStack(spacing: 8) {
            if let ask = browser.capture.asking {
                CaptureQuestion(ask: ask, capture: browser.capture).transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let offer = browser.logins.offer {
                SaveQuestion(offer: offer, logins: browser.logins).transition(.move(edge: .bottom).combined(with: .opacity))
            }
            StoreOffer(browser: browser)
            if browser.pickingElement {
                Text("Click anything to hide it   ⌘Z undo   esc done")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ground.opacity(0.92))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(Palette.ink.opacity(0.92), in: Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 30)
        .animation(Motion.settle, value: browser.pickingElement)
        .animation(Motion.settle, value: browser.capture.asking)
        .animation(Motion.settle, value: browser.logins.offer)
    }
}

/// The short messages, apart from the window's other views: the browser
/// doesn't pass on their changes, and Core Animation fades and lifts the
/// card, so one coming neither redraws the window nor lays it out again on
/// every frame of its arrival.
@MainActor
final class Announcer: ObservableObject {
    @Published var showing: Announcement?
}

/// The message showing, in a view of its own over the window's foot.
struct Toast: NSViewRepresentable {
    @ObservedObject var announcer: Announcer
    let browser: Browser

    func makeNSView(context: Context) -> Holder { Holder() }

    func updateNSView(_ holder: Holder, context: Context) {
        holder.show(announcer.showing.map { AnyView(AnnouncementCard(message: $0, browser: browser)) })
    }

    final class Holder: NSView {
        private var host: NSHostingController<AnyView>?
        private var card: NSView? { host?.view }
        /// Room for the card's shadow, and its place above the window's foot.
        private static let margin: CGFloat = 40
        private static let foot: CGFloat = 30
        private static let rise: CGFloat = 14

        override var isFlipped: Bool { true }

        /// Only the card takes clicks.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let card, card.alphaValue > 0,
                card.frame.insetBy(dx: Self.margin, dy: Self.margin).contains(convert(point, from: superview))
            else { return nil }
            return super.hitTest(point)
        }

        override func layout() {
            super.layout()
            if let host { host.view.frame = place(host) }
        }

        private func place(_ host: NSHostingController<AnyView>) -> NSRect {
            let size = host.sizeThatFits(in: CGSize(width: min(bounds.width, 460) + Self.margin * 2, height: 10_000))
            return NSRect(
                x: (bounds.width - size.width) / 2, y: bounds.height - Self.foot - size.height + Self.margin, width: size.width,
                height: size.height)
        }

        func show(_ content: AnyView?) {
            guard let content else { return hide() }
            let fresh = card == nil || card?.alphaValue == 0
            let host = host ?? made()
            host.rootView = AnyView(content.padding(Self.margin))
            let card = host.view
            let target = place(host)
            guard fresh, window != nil else { return card.frame = target }
            card.alphaValue = 0
            card.frame = target.offsetBy(dx: 0, dy: Self.rise)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                card.animator().alphaValue = 1
                card.animator().frame = target
            }
        }

        private func made() -> NSHostingController<AnyView> {
            let made = NSHostingController(rootView: AnyView(EmptyView()))
            made.sizingOptions = []
            made.safeAreaRegions = []
            made.view.alphaValue = 0
            addSubview(made.view)
            host = made
            return made
        }

        private func hide() {
            guard let card, card.alphaValue > 0 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                card.animator().alphaValue = 0
                card.animator().frame = card.frame.offsetBy(dx: 0, dy: Self.rise)
            }
        }
    }
}

/// A message: a card with its symbol, its line (and a second one), and a
/// button when there's something to do. Resting on it keeps it up.
private struct AnnouncementCard: View {
    let message: Announcement
    let browser: Browser
    @State private var hovering = false

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    /// A line alone, like a zoom level, stays small.
    private var slim: Bool { message.detail == nil && message.action == nil && message.symbol == nil }

    var body: some View {
        HStack(spacing: 12) {
            if let symbol = message.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 32, height: 32)
                    .background(Palette.wash, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(message.text).font(.system(size: 13, weight: slim ? .regular : .semibold)).foregroundStyle(Palette.ink)
                if let detail = message.detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let action = message.action {
                Spacer(minLength: 8)
                Button {
                    browser.dismissAnnouncement()
                    action.perform()
                } label: {
                    Text(action.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Palette.ink, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, slim ? 10 : 12)
        .padding(.leading, message.symbol == nil ? 16 : 12)
        .padding(.trailing, message.action == nil ? 16 : 12)
        .frame(maxWidth: 460)
        .fixedSize(horizontal: slim, vertical: true)
        .background(Palette.ground, in: shape)
        .overlay(shape.strokeBorder(Palette.hairline))
        .shadow(color: .black.opacity(0.07), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.16), radius: 26, y: 12)
        .overlay(alignment: .topTrailing) {
            if hovering, !slim {
                Button(action: browser.dismissAnnouncement) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 18, height: 18)
                        .background(Palette.ground, in: Circle())
                        .overlay(Circle().strokeBorder(Palette.hairline))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .transition(.opacity)
            }
        }
        .onHover { inside in
            withAnimation(Motion.hover) { hovering = inside }
            browser.holdAnnouncement(inside)
        }
    }
}

/// A site asking for the camera or microphone. The answer is remembered.
private struct CaptureQuestion: View {
    let ask: CaptureRequests.Ask
    let capture: CaptureRequests

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ask.wants == "microphone" ? "mic" : "video").font(.system(size: 11, weight: .medium)).foregroundStyle(
                Palette.muted)
            Text("\(ask.host) would like to use your \(ask.wants)").textStyle(.row)
            BubbleButton("Allow", filled: true, act: capture.allow)
            BubbleButton("Don't Allow", act: capture.deny)
        }
        .padding(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 10))
        .bubble()
    }
}

/// Saving or updating a password after a sign-in. The password isn't shown.
private struct SaveQuestion: View {
    let offer: Logins.Offer
    let logins: Logins

    private var question: String {
        let login = offer.login
        if offer.changed { return "Update the saved password for \(login.user) on \(login.host)?" }
        return login.user.isEmpty ? "Save a password for \(login.host)?" : "Save the password for \(login.user) on \(login.host)?"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(question).textStyle(.row).lineLimit(1)
            BubbleButton(offer.changed ? "Update" : "Save", filled: true, act: logins.keepOffer)
            BubbleButton("Not Now", act: logins.dropOffer)
            if !offer.changed { BubbleButton("Never for This Site", act: logins.neverOffer) }
        }
        .padding(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 12))
        .bubble()
    }
}

/// A button in a notice: filled for the answer that does something.
private struct BubbleButton: View {
    let title: String
    var filled = false
    let act: () -> Void

    init(_ title: String, filled: Bool = false, act: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.act = act
    }

    var body: some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(filled ? Palette.ground : Palette.muted)
                .padding(.horizontal, filled ? 11 : 0)
                .padding(.vertical, 5)
                .background(filled ? Palette.ink : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// A floating capsule on the ground, outlined, with a soft shadow.
    func bubble(shadow: Double = 0.12, radius: CGFloat = 20) -> some View {
        background(Palette.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .shadow(color: .black.opacity(shadow), radius: radius, y: 6)
    }
}
