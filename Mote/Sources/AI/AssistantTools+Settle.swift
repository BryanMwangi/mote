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
}
