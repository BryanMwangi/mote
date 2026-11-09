import AppKit

/// Handoff, as Safari, Chrome and Firefox do it.
/// - Out: each window offers its front tab's page, so an iPhone, iPad or
///   another Mac can carry on from it. AppKit makes the key window's activity
///   the current one.
/// - In: a page handed off from another device opens here, when Mote is the
///   default browser (Info.plist declares the browsing activity).
///
/// Private windows and private tabs offer nothing.
@MainActor
enum Handoff {
    /// Offers `url` from `window`, or nothing.
    static func offer(_ url: URL?, title: String, from window: NSWindow, shy: Bool) {
        guard !shy, let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            window.userActivity?.invalidate()
            window.userActivity = nil
            return
        }
        if let activity = window.userActivity, activity.webpageURL == url {
            activity.title = title
            return
        }
        window.userActivity?.invalidate()
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        activity.title = title
        activity.isEligibleForHandoff = true
        window.userActivity = activity
        if window.isKeyWindow { activity.becomeCurrent() }
    }

    /// A page from another device, in a new tab of the window in front.
    static func take(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL,
            ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return false }
        LinkInbox.take(url)
        return true
    }
}
