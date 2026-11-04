import Foundation

/// What every window shares: the settings, history, bookmarks, downloads and
/// hidden elements, each loaded once from its file. Each window's Browser
/// points at these (see Windows.swift).
@MainActor
final class AppState {
    static let shared = AppState()

    let prefs = Preferences()
    let history = History()
    let bookmarks = Bookmarks()
    let downloads = Downloads()
    let elementHider = ElementHider()

    private init() {}
}
