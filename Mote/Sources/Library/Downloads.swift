import AppKit
import Combine
import MoteCore
import WebKit

/// The downloads: those under way or stopped short (`transfers`), and the
/// recent finished ones, kept in downloads.json. Starting one is
/// Browser+Navigation's.
@MainActor
final class Downloads: ObservableObject {
    @Published private var list = DownloadList()
    private let file = JSONFile<[DownloadRecord]>("downloads.json")

    /// Under way, paused or failed, newest first.
    @Published private(set) var transfers: [Transfer] = []
    /// The paused and failed ones, so they can go on after a relaunch.
    private let stopped = JSONFile<[Transfer.Saved]>("downloads-stopped.json")
    /// Reads how far the running ones have got, a few times a second.
    private var ticker: Timer?
    /// How far all those running have got together, for the sidebar's button;
    /// nil while none runs, and 0 while none knows its size.
    @Published private(set) var running: Double?

    var kept: [DownloadRecord] { list.records }
    /// Kept files no longer where they were saved, by id: looked for again
    /// whenever Mote comes forward, as they're deleted or moved in the
    /// Finder, and when a list of them opens.
    @Published private(set) var missing: Set<String> = []
    private var comingForward: Any?

    init() {
        list = DownloadList(file.load() ?? [])
        transfers = (stopped.load() ?? []).map(Transfer.init(saved:))
        lookAgain()
        comingForward = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.lookAgain() } }
    }

    func lookAgain() {
        let gone = Set(kept.filter { !$0.stillThere }.map(\.id))
        if gone != missing { missing = gone }
    }

    func isThere(_ record: DownloadRecord) -> Bool { !missing.contains(record.id) }

    func add(_ record: DownloadRecord) { change { $0.add(record) } }
    func forget(_ record: DownloadRecord) { change { $0.remove(record.id) } }
    /// Empties the list; the files stay.
    func forgetAll() { change { $0.removeAll() } }

    func reveal(_ record: DownloadRecord) { NSWorkspace.shared.activateFileViewerSelecting([record.url]) }
    func open(_ record: DownloadRecord) { NSWorkspace.shared.open(record.url) }

    /// The file to the Trash, and off the list.
    func trash(_ record: DownloadRecord) {
        NSWorkspace.shared.recycle([record.url]) { [weak self] _, _ in MainActor.assumeIsolated { self?.forget(record) } }
    }

    static func copy(_ link: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    private func change(_ edit: (inout DownloadList) -> Void) {
        edit(&list)
        file.save(list.records)
        lookAgain()
    }

    // MARK: - Under way

    func transfer(for download: WKDownload) -> Transfer? { transfers.first { $0.download === download } }

    /// A download has begun; a resumed one carries on in its own row.
    func began(_ download: WKDownload, resuming: Transfer? = nil) {
        let transfer = resuming ?? Transfer(source: download.originalRequest?.url)
        transfer.follow(download)
        if resuming == nil { transfers.insert(transfer, at: 0) }
        noteRunning()
        tick()
    }

    /// Done: into the list of files, out of the running ones.
    func finished(_ download: WKDownload) -> DownloadRecord? {
        guard let transfer = transfer(for: download) else { return nil }
        drop(transfer)
        noteRunning()
        guard let path = transfer.file?.path ?? download.progress.fileURL?.path else { return nil }
        let record = DownloadRecord(name: transfer.name, from: transfer.from, path: path, date: Date(), source: transfer.source)
        add(record)
        return record
    }

    /// Failed, or stopped by WebKit: kept with what's needed to go on.
    func failed(_ download: WKDownload, resumeData: Data?) {
        guard let transfer = transfer(for: download), transfer.state == .running else { return }
        transfer.stop(.failed, resumeData: resumeData)
        save()
    }

    func pause(_ transfer: Transfer) {
        guard let download = transfer.download else { return }
        transfer.state = .paused
        download.cancel { [weak self] data in
            MainActor.assumeIsolated {
                transfer.stop(.paused, resumeData: data)
                self?.save()
            }
        }
    }

    /// Goes on from where it stopped, in `page`'s website data (its sign-in);
    /// from the start when the part already fetched has gone.
    func resume(_ transfer: Transfer, in page: WKWebView, follow: @escaping @MainActor (WKDownload) -> Void) {
        transfer.state = .running
        let begin: @MainActor (WKDownload) -> Void = { [weak self] download in
            follow(download)
            self?.began(download, resuming: transfer)
            self?.save()
        }
        if let data = transfer.resumeData {
            page.resumeDownload(fromResumeData: data) { download in MainActor.assumeIsolated { begin(download) } }
        } else if let source = transfer.source {
            page.startDownload(using: URLRequest(url: source)) { download in MainActor.assumeIsolated { begin(download) } }
        }
    }

    /// Stops it and forgets it; a file only partly written goes too.
    func cancel(_ transfer: Transfer) {
        transfer.download?.cancel()
        drop(transfer)
        save()
    }

    /// Works out `running` again, published only as it moves a little.
    func noteRunning() {
        let running = transfers.filter { $0.state == .running }
        let sized = running.filter { $0.total > 0 }
        let done = Double(sized.map(\.received).reduce(0, +)) / Double(max(1, sized.map(\.total).reduce(0, +)))
        let now: Double? = running.isEmpty ? nil : done
        if let now, let was = self.running, abs(now - was) < 0.005 { return }
        if now != self.running { self.running = now }
    }

    private func drop(_ transfer: Transfer) {
        transfers.removeAll { $0 === transfer }
        transfer.forgetResumeData()
    }

    private func save() {
        stopped.save(transfers.filter { $0.state != .running }.map(\.saved))
        noteRunning()
    }

    /// Progress isn't published as it comes, which can be thousands of times
    /// a second: it's read twice a second while anything runs.
    private func tick() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let running = self.transfers.filter { $0.state == .running }
                running.forEach { $0.read() }
                self.noteRunning()
                if running.isEmpty {
                    self.ticker?.invalidate()
                    self.ticker = nil
                }
            }
        }
    }
}

/// One download under way, paused or failed. Its row redraws alone as it moves.
@MainActor
final class Transfer: ObservableObject, Identifiable {
    nonisolated enum State: String, Codable, Sendable { case running, paused, failed }

    /// What's kept of a stopped one: its resume data goes in a file of its own.
    nonisolated struct Saved: Codable, Sendable {
        var id: UUID
        var source: URL?
        var from: String
        var file: URL?
        var state: State
        var received: Int64
        var total: Int64
    }

    let id: UUID
    let source: URL?
    let from: String
    /// Where it's being written, once decided.
    var file: URL?
    @Published var state: State = .running
    @Published private(set) var received: Int64 = 0
    @Published private(set) var total: Int64 = 0
    /// Bytes a second lately, smoothed; 0 until there are two readings.
    @Published private(set) var rate: Double = 0
    private var lastRead: (at: Date, received: Int64)?
    private(set) weak var download: WKDownload?
    /// WebKit's, to go on from where it stopped.
    private(set) var resumeData: Data?

    init(source: URL?) {
        id = UUID()
        self.source = source
        from = source?.host() ?? ""
    }

    init(saved: Saved) {
        id = saved.id
        source = saved.source
        from = saved.from
        file = saved.file
        // One running when Mote quit stopped with it.
        state = saved.state == .running ? .paused : saved.state
        received = saved.received
        total = saved.total
        resumeData = try? Data(contentsOf: resumeFile)
    }

    var saved: Saved { Saved(id: id, source: source, from: from, file: file, state: state, received: received, total: total) }

    var name: String { file?.lastPathComponent ?? source?.lastPathComponent ?? "download" }
    /// How much is done, when the size is known.
    var fraction: Double? { total > 0 ? min(1, Double(received) / Double(total)) : nil }

    func follow(_ download: WKDownload) {
        self.download = download
        state = .running
        read()
    }

    func read() {
        guard let progress = download?.progress else { return }
        let now = Date(), got = progress.completedUnitCount
        if let last = lastRead, now.timeIntervalSince(last.at) > 0.2 {
            let lately = Double(got - last.received) / now.timeIntervalSince(last.at)
            rate = rate == 0 ? lately : rate * 0.7 + lately * 0.3
        }
        if lastRead == nil || now.timeIntervalSince(lastRead!.at) > 0.2 { lastRead = (now, got) }
        if received != got { received = got }
        if total != progress.totalUnitCount { total = max(0, progress.totalUnitCount) }
    }

    func stop(_ state: State, resumeData: Data?) {
        read()
        rate = 0
        lastRead = nil
        self.state = state
        self.resumeData = resumeData
        download = nil
        if let resumeData {
            try? FileManager.default.createDirectory(at: resumeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? resumeData.write(to: resumeFile)
        } else {
            forgetResumeData()
        }
    }

    func forgetResumeData() { try? FileManager.default.removeItem(at: resumeFile) }

    private var resumeFile: URL { Storage.file("Stopped downloads/\(id.uuidString)") }
}

extension DownloadRecord {
    var stillThere: Bool { FileManager.default.fileExists(atPath: path) }
}
