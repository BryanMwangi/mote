import MoteCore
import SwiftUI

/// The Library, as Zen's: history, downloads and bookmarks in one place, a
/// tab strip above whichever of their panels is open to go between them.
/// Each panel is the one it always was.
enum LibrarySection: String, CaseIterable {
    case history = "History", downloads = "Downloads", bookmarks = "Bookmarks"

    var symbol: String {
        switch self {
        case .history: "clock"
        case .downloads: "arrow.down.circle"
        case .bookmarks: "bookmark"
        }
    }
}

extension Browser {
    /// Which of the Library's panels is open, if one is.
    var librarySection: LibrarySection? {
        recalling ? .history : showingDownloads ? .downloads : bookmarking ? .bookmarks : nil
    }

    /// Opens a section, closing the one that was open.
    func showLibrary(_ section: LibrarySection) {
        withAnimation(Motion.quick) {
            recalling = section == .history
            showingDownloads = section == .downloads
            bookmarking = section == .bookmarks
        }
        Storage.settings.set(section.rawValue, forKey: "library.section")
    }

    /// The Library, where it was last left; closed again if it's open.
    func toggleLibrary() {
        if librarySection != nil { return closeLibrary() }
        showLibrary(LibrarySection(rawValue: Storage.settings.string(forKey: "library.section") ?? "") ?? .history)
    }

    func closeLibrary() {
        recalling = false
        showingDownloads = false
        bookmarking = false
    }
}

/// The strip above a Library panel.
struct LibraryTabs: View {
    @ObservedObject var browser: Browser

    var body: some View {
        HStack(spacing: 4) {
            ForEach(LibrarySection.allCases, id: \.self) { section in
                let here = browser.librarySection == section
                Button {
                    browser.showLibrary(section)
                } label: {
                    Label(section.rawValue, systemImage: section.symbol)
                        .font(.system(size: 12, weight: here ? .semibold : .regular))
                        .foregroundStyle(here ? Palette.ink : Palette.muted)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(here ? Palette.wash : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }
}

/// A Library panel with the strip above it.
struct LibraryShelf<Panel: View>: View {
    @ObservedObject var browser: Browser
    @ViewBuilder let panel: () -> Panel

    var body: some View {
        VStack(spacing: 10) {
            LibraryTabs(browser: browser)
            panel()
        }
    }
}
