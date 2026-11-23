import Foundation

/// How work in a page came out: done, cut short by the page going elsewhere,
/// or still going when the wait ran out.
enum Settled<Value> {
    case done(Value)
    case went(URL?)
    case late
}

extension AssistantTools {
    /// Waits for `work` to answer, unless the tab goes to another page first
    /// (a script or a click that navigates never answers) or `seconds` pass.
    /// Whichever comes first is the answer; the others are let go.
    func settle<Value>(
        _ tab: Tab, within seconds: Double, _ work: (@escaping (Value) -> Void) -> Void
    ) async -> Settled<Value> {
        let from = tab.address
        let wasLoading = tab.loading
        return await withCheckedContinuation { done in
            var answered = false
            let give = { (outcome: Settled<Value>) in
                guard !answered else { return }
                answered = true
                done.resume(returning: outcome)
            }
            work { value in MainActor.assumeIsolated { give(.done(value)) } }
            Task { @MainActor in
                let end = Date().addingTimeInterval(seconds)
                var leaving: Date?
                while !answered {
                    if tab.address != from { return give(.went(tab.address)) }
                    // Loading another page: its address comes in a moment.
                    if !wasLoading, tab.loading, leaving == nil { leaving = Date() }
                    if let leaving, Date().timeIntervalSince(leaving) > 3 { return give(.went(nil)) }
                    if Date() > end { return give(.late) }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    /// What a click or a key set off beyond the page, watched for a second:
    /// a tab it opened, or the page it went to. Nothing when neither.
    func aftermath(of tab: Tab, had: Set<ObjectIdentifier>, from: URL?) async -> String {
        let wasLoading = tab.loading
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(100))
            if let opened = everyTab.first(where: { !had.contains(ObjectIdentifier($0.tab)) && $0.tab.opener == tab.id })?.tab {
                let going = (opened.pending ?? opened.address).map { ", for \($0.absoluteString)" } ?? ""
                return " It opened a new tab, \(Self.id(opened))\(going); this tab stayed where it was."
            }
            if tab.address != from { return " The page went to \(tab.address?.absoluteString ?? "another page")." }
        }
        return !wasLoading && tab.loading ? " The page is loading something new; read it once it has." : ""
    }
}
