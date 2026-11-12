import SwiftUI

/// A site's question about the camera, the microphone or notifications, in a
/// popover from the page button: the site and what it wants, whether to
/// remember the answer, and Block or Allow.
struct PermissionCard: View {
    let ask: SitePermissions.Ask
    let permissions: SitePermissions
    @ObservedObject var tab: Tab
    @State private var remember = true

    private static let width: CGFloat = 310

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Mark(icon: tab.icon, letter: tab.monogram, size: 28)
                Text("Allow \(ask.host) to \(ask.kind.what)?")
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 28)
            }
            Toggle("Remember for this site", isOn: $remember)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            HStack(spacing: 8) {
                Spacer()
                Pill("Block") { permissions.answer(ask, allow: false, remember: remember) }
                Pill("Allow", filled: true) { permissions.answer(ask, allow: true, remember: remember) }
            }
        }
        // The system's own text colour throughout: a grey of Mote's would
        // fade over the light page the popover's glass lets through.
        .foregroundStyle(.primary)
        .padding(14)
        .frame(width: Self.width)
    }
}
