import Combine
import Darwin
import MoteCore
import SwiftUI
import WebKit

/// About Processes, as Firefox's: each web process with the tabs it runs,
/// what memory it holds and how busy it is, every two seconds while open;
/// a tab can be unloaded or closed from here.
struct ProcessesPanel: View {
    @ObservedObject var browser: Browser
    @State private var rows: [ProcessRow] = []
    @State private var last: [pid_t: (ticks: UInt64, at: UInt64)] = [:]

    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Plate("Processes", width: 600, close: { browser.showingProcesses = false }) {
            ScrollView(showsIndicators: false) {
                Card {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Rule() }
                        ProcessLine(row: row, browser: browser)
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 440)
        } foot: {
            HStack {
                Text("Tabs on the same site share a process, in every space. Resting tabs have none.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
            }
        }
        .onAppear(perform: measure)
        .onReceive(tick) { _ in measure() }
    }

    /// Every web view by its web process, Mote itself first: each window's
    /// tabs in every space, link previews, and the pages that aren't tabs.
    private func measure() {
        var byProcess: [pid_t: [ProcessRow.Page]] = [:]
        for window in Windows.shared.all {
            let previews = [window.peekTab].compactMap { $0 } + window.parkedPeeks.values.map(\.tab)
            let places =
                window.tabs.map { ($0, nil as String?) }
                + window.parked.flatMap { space, parked in
                    let name = window.spaces.first { $0.id == space }?.name ?? "another space"
                    return parked.tabs.map { ($0, "in \(name)" as String?) }
                }
                + previews.map { ($0, "preview" as String?) }
            for (tab, place) in places {
                guard let pid = tab.built?.unpublishedPID("_webProcessIdentifier"), pid > 0 else { continue }
                byProcess[pid, default: []].append(.tab(tab, place))
            }
        }
        for web in Web.named.keyEnumerator().allObjects.compactMap({ $0 as? WKWebView }) {
            guard let pid = web.unpublishedPID("_webProcessIdentifier"), pid > 0, let label = Web.named.object(forKey: web) else { continue }
            byProcess[pid, default: []].append(.other(label as String))
        }
        let now = mach_absolute_time()
        var seen: [pid_t: (ticks: UInt64, at: UInt64)] = [:]
        rows = ([(getpid(), [ProcessRow.Page]())] + byProcess.sorted { $0.key < $1.key }).compactMap { pid, pages in
            var info = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard read == 0 else { return nil }
            let ticks = info.ri_user_time + info.ri_system_time
            seen[pid] = (ticks, now)
            let busy = last[pid].map { before in
                Double(ticks &- before.ticks) / Double(max(1, now &- before.at)) * 100
            }
            return ProcessRow(id: pid, pages: pages, memory: info.ri_phys_footprint, cpu: busy)
        }
        last = seen
    }
}

struct ProcessRow: Identifiable {
    /// What a process runs: a tab (where, when it isn't in front), or a page that isn't one.
    enum Page: Identifiable {
        case tab(Tab, String?)
        case other(String)

        var id: String {
            switch self {
            case .tab(let tab, _): tab.id.uuidString
            case .other(let label): label
            }
        }
    }

    let id: pid_t
    /// None for Mote's own process.
    let pages: [Page]
    let memory: UInt64
    /// Percent of one core since the last look; nil the first time.
    let cpu: Double?
}

private struct ProcessLine: View {
    let row: ProcessRow
    let browser: Browser

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.pages.isEmpty ? "Mote" : "Web content").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                Text("pid \(row.id)").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Palette.muted)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(row.memory), countStyle: .memory))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted)
                    .frame(width: 80, alignment: .trailing)
                Text(row.cpu.map { String(format: "%.0f%%", $0) } ?? "–")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted)
                    .frame(width: 44, alignment: .trailing)
            }
            ForEach(row.pages) { page in
                HStack(spacing: 8) {
                    switch page {
                    case .tab(let tab, let place):
                        Mark(icon: tab.icon, letter: tab.monogram, size: 14, mote: false)
                        Text(tab.label).font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(1)
                        if let place { Text(place).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1).fixedSize() }
                        Spacer()
                        if place != "preview" {
                            Pill("Unload") { (tab.owner as? Browser)?.unload(tab) }
                            Pill("Close") { (tab.owner as? Browser)?.close(tab) }
                        }
                    case .other(let label):
                        Image(systemName: "square.dashed").font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14)
                        Text(label).font(.system(size: 12.5)).foregroundStyle(Palette.muted).lineLimit(1)
                        Spacer()
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
