import Combine
import Darwin
import SwiftUI

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
                Text("Tabs on the same site share a process. Resting tabs have none.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
            }
        }
        .onAppear(perform: measure)
        .onReceive(tick) { _ in measure() }
    }

    /// Every window's tabs by their web process, Mote itself first.
    private func measure() {
        var byProcess: [pid_t: [Tab]] = [:]
        for tab in Windows.shared.all.flatMap(\.tabs) {
            guard let pid = tab.built?.unpublishedPID("_webProcessIdentifier"), pid > 0 else { continue }
            byProcess[pid, default: []].append(tab)
        }
        let now = mach_absolute_time()
        var seen: [pid_t: (ticks: UInt64, at: UInt64)] = [:]
        rows = ([(getpid(), [Tab]())] + byProcess.sorted { $0.key < $1.key }).compactMap { pid, tabs in
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
            return ProcessRow(id: pid, tabs: tabs, memory: info.ri_phys_footprint, cpu: busy)
        }
        last = seen
    }
}

struct ProcessRow: Identifiable {
    let id: pid_t
    /// None for Mote's own process.
    let tabs: [Tab]
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
                Text(row.tabs.isEmpty ? "Mote" : "Web content").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                Text("pid \(row.id)").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Palette.muted)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(row.memory), countStyle: .memory))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted)
                    .frame(width: 80, alignment: .trailing)
                Text(row.cpu.map { String(format: "%.0f%%", $0) } ?? "–")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted)
                    .frame(width: 44, alignment: .trailing)
            }
            ForEach(row.tabs) { tab in
                HStack(spacing: 8) {
                    Mark(icon: tab.icon, letter: tab.monogram, size: 14, mote: false)
                    Text(tab.label).font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(1)
                    Spacer()
                    Pill("Unload") { (tab.owner as? Browser)?.unload(tab) }
                    Pill("Close") { (tab.owner as? Browser)?.close(tab) }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
