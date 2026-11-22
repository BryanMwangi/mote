import MoteAI
import SwiftUI

/// A chat in a tab: the conversation in a readable column, and a composer
/// along the bottom for the next message. Questions sit in bubbles on the
/// right; answers read as plain text, signed with who wrote them.
///
/// Its two slots are for the page chat: `start` stands in for the empty
/// conversation (its quick actions), and `accessory` sits above the composer
/// (its context chip). A blank tab's chat leaves both empty.
struct ChatView<Accessory: View, Start: View>: View {
    /// Not observed: the browser changes all the time, and the chat would
    /// redraw with it. What the chat shows of it is read where it's used.
    let browser: Browser
    let conversation: Conversation
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let start: () -> Start
    /// Run before a question goes, so the page chat can share the page on its
    /// first turn; the question waits for it. Main-actor, not nonisolated:
    /// a nonisolated async function type's metadata needs macOS 15's Swift
    /// runtime, and SwiftUI reads it from the view's fields on macOS 14 too.
    var beforeSend: (@MainActor () async -> Void)? = nil
    /// The surface the conversation reads on: the card for a chat in a tab, the
    /// window frame for the page chat docked on it, the mirror of the sidebar.
    var ground: Color = Palette.ground
    /// What the conversation fades into under the composer; the ground if not given.
    var fade: Color? = nil
    /// A draft the composer opens with, seeded from outside — the page chat
    /// puts the selection asked about here. Taken up once, then reported
    /// through `took`, so it is not put back on the next draw.
    var seed: String? = nil
    var took: () -> Void = {}
    /// /new and /clear: a fresh chat where this one is.
    var newChat: (() -> Void)? = nil

    /// Held apart from the view, so typing redraws only the composer.
    @State private var draft = Draft()
    @State private var inputHeight = ChatInput.line
    @State private var focus = 0
    /// /usage: what the chat has spent, over the composer until closed.
    @State private var showsUsage = false
    /// How far the end of the conversation is below the view: only which
    /// zone, so scrolling changes it a few times rather than every frame.
    @State private var distance = ScrollDistance.end
    /// Keeping to the end as the reply grows; scrolling up to read lets go,
    /// and coming back down takes it up again.
    @State private var pinned = true
    /// How tall what sits over the end is: the page chip, mentions, composer.
    @State private var overEnd: CGFloat = 0

    static var column: CGFloat { 720 }
    private static var end: String { "end" }

    var body: some View {
        ScrollViewReader { scroller in
            ZStack(alignment: .bottom) {
                // The thin thumb the tab list has, with no track or border.
                follow(ScrollView { transcript }.floatingScrollBar().coordinateSpace(name: "chat"), scroller)
                    .onChange(of: distance) { _, now in if now == .end { pinned = true } }
                    .onScrollUp { pinned = false }

                VStack(spacing: 10) {
                    if distance == .far {
                        JumpDown {
                            pinned = true
                            withAnimation(Motion.glide) { scroller.scrollTo(Self.end, anchor: .bottom) }
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    VStack(spacing: 10) {
                        if showsUsage { UsageCard(conversation: conversation) { showsUsage = false }.frame(maxWidth: Self.column) }
                        accessory()
                        if !conversation.mentions.isEmpty { mentioned(conversation) }
                        ChatTray(conversation: conversation).frame(maxWidth: Self.column)
                        ChatComposer(
                            browser: browser, conversation: conversation,
                            draft: Binding(get: { draft.text }, set: { draft.text = $0 }), height: $inputHeight, focus: focus,
                            mentionables: { mentionables }, choseMention: chose, send: send
                        )
                        .frame(maxWidth: Self.column)
                    }
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        overEnd = $0
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity)
                .background(alignment: .bottom) {
                    // The conversation fades out under the composer.
                    LinearGradient(
                        colors: [(fade ?? ground).opacity(0), fade ?? ground], startPoint: .top, endPoint: .init(x: 0.5, y: 0.45)
                    )
                    .frame(height: max(inputHeight + 110, overEnd + 24))
                    .allowsHitTesting(false)
                }
                .animation(Motion.quick, value: distance == .far)
            }
        }
        .background(ground)
        .onAppear {
            focus += 1
            take()
        }
        .onChange(of: seed) { _, _ in take() }
        .environment(
            \.openURL,
            OpenURLAction { url in
                // From the chat's tab, so a private chat's links open privately.
                browser.open(url, foreground: true, from: browser.active)
                return .handled
            })
    }

    /// The messages, the working line, and room at the end for what sits over it.
    private var transcript: some View {
        let messages = conversation.messages
        // Where the chat was summarised, before the first message after.
        let summarisedAt =
            conversation.summarised > 0 && conversation.summarised < messages.count ? messages[conversation.summarised].id : nil
        return VStack(alignment: .leading, spacing: 26) {
            if messages.isEmpty { start() }
            // Built as they scroll into view: a long chat lays out only what shows.
            LazyVStack(alignment: .leading, spacing: 26) {
                ForEach(messages) { message in
                    row(message, last: message.id == messages.last?.id, summarisedBefore: message.id == summarisedAt)
                }
            }
            Status(browser: browser, conversation: conversation, retry: retry)
            if conversation.summarised == conversation.messages.count, conversation.summarised > 0, let summary = conversation.summary {
                SummaryDivider(summary: summary)
            }
            // Room for everything over the end; scrolling to it shows the last line above them.
            Color.clear.frame(height: max(inputHeight + 96, overEnd + 28)).id(Self.end)
                .onGeometryChange(for: ScrollDistance.self) { proxy in
                    let view = proxy.bounds(of: .named("chat"))?.height ?? 0
                    return ScrollDistance(below: proxy.frame(in: .named("chat")).maxY - view)
                } action: {
                    distance = $0
                }
        }
        .frame(maxWidth: Self.column, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 32)
        .frame(maxWidth: .infinity)
        .animation(Motion.settle, value: conversation.messages.count)
    }

    @ViewBuilder
    private func row(_ message: Message, last: Bool, summarisedBefore: Bool) -> some View {
        if summarisedBefore, let summary = conversation.summary {
            SummaryDivider(summary: summary)
        }
        MessageRow(message: message, last: last, streaming: last && conversation.busy).equatable()
            .environment(\.chatActions, actions)
            .transition(.opacity.combined(with: .offset(y: 6)))
    }

    /// Keeps to the end as the reply grows, unless scrolled up to read; opens there.
    private func follow(_ view: some View, _ scroller: ScrollViewProxy) -> some View {
        let toEnd = { if pinned { scroller.scrollTo(Self.end, anchor: .bottom) } }
        return
            view
            .onChange(of: conversation.messages.last?.text) { toEnd() }
            .onChange(of: conversation.messages.count) {
                pinned = true
                withAnimation(Motion.settle) { scroller.scrollTo(Self.end, anchor: .bottom) }
            }
            // Steps, the working line and what's over the end grow it too, not only the text.
            .onChange(of: conversation.messages.last?.steps.count) { toEnd() }
            .onChange(of: conversation.activities.count) { toEnd() }
            .onChange(of: conversation.phase) { toEnd() }
            .onChange(of: overEnd) { toEnd() }
            .onAppear { DispatchQueue.main.async { scroller.scrollTo(Self.end, anchor: .bottom) } }
    }

    private var actions: ChatActions { ChatActions(retry: retry) }

    private func send() {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft.text = ""
        if text == Skill.compact.prompt { return Assistant.shared.compact(conversation) }
        if text == Skill.usage.prompt { return withAnimation(Motion.quick) { showsUsage = true } }
        if text == Skill.background.prompt {
            let behind = ChatModes.shared.toggleBehind(conversation.id, else: browser.prefs.aiBackground)
            return browser.announce(behind ? "This chat works in the background: tabs stay behind the one you're on" : "This chat brings each tab it starts on forward")
        }
        if text == Skill.new.prompt || text == Skill.clear.prompt { return (newChat ?? browser.newAskingTab)() }
        guard let beforeSend else { return Assistant.shared.ask(text, in: conversation) }
        Task {
            await beforeSend()
            Assistant.shared.ask(text, in: conversation)
        }
    }

    private func retry() { Assistant.shared.retry(in: conversation) }

    /// Takes up a seeded draft: the selection asked about, quoted, ready to
    /// send or edit. Reported taken so the panel does not put it back.
    private func take() {
        guard let seed, !seed.isEmpty else { return }
        draft.text = seed
        Task { @MainActor in took() }
    }

    // MARK: - Mentioned tabs

    /// The other open tabs the @-picker may offer: this window's named tabs
    /// but the one this chat is about, and none already mentioned. Empty once
    /// the chat holds as many as it may.
    private var mentionables: [MentionMenu.Candidate] {
        guard conversation.mentions.count < Conversation.mentionLimit else { return [] }
        return browser.mentionCandidates(excluding: browser.active, mentioned: Set(conversation.mentions.map(\.url)))
    }

    /// Shares a chosen tab with the chat as further context. Taken up at once
    /// with its name and address, so its chip shows on the first frame, and
    /// its text read after; a late read attaches only while the tab is still
    /// open and still mentioned.
    private func chose(_ candidate: MentionMenu.Candidate) {
        guard let tab = browser.tabs.first(where: { $0.id.uuidString == candidate.id }), let url = tab.address else { return }
        conversation.mention(PageContext(url: url, title: tab.title))
        Task { [weak conversation] in
            guard browser.tab(tab.id) != nil, conversation?.mentions.contains(where: { $0.url == url }) == true,
                let page = await tab.capturePageContext()
            else { return }
            conversation?.mention(page)
        }
    }

    /// The tabs mentioned with @, each a small chip that lets it go.
    private func mentioned(_ conversation: Conversation) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(conversation.mentions, id: \.url) { page in
                    ContextChip(title: page.title.isEmpty ? (page.url.host() ?? page.url.absoluteString) : page.title) {
                        conversation.unmention(page.url)
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxWidth: Self.column, alignment: .leading)
    }

}

extension ChatView where Accessory == EmptyView, Start == EmptyView {
    /// A chat with no page slots: the blank tab's, as before.
    init(browser: Browser, conversation: Conversation) {
        self.init(browser: browser, conversation: conversation, accessory: { EmptyView() }, start: { EmptyView() })
    }
}

/// How far below the view the end of the conversation is.
nonisolated enum ScrollDistance: Equatable, Sendable {
    /// At the end, or nearly: following the reply.
    case end
    /// A little way up.
    case near
    /// Far enough up to offer the way back down.
    case far

    init(below: CGFloat) {
        self = below < 24 ? .end : below < 240 ? .near : .far
    }
}

/// What a message's buttons do, handed down to the rows.
struct ChatActions {
    var retry: () -> Void = {}
}

extension EnvironmentValues {
    @Entry var chatActions = ChatActions()
}

// MARK: - Messages

/// One message. Equatable, so a streaming reply redraws only itself.
private struct MessageRow: View, Equatable {
    let message: Message
    let last: Bool
    let streaming: Bool

    var body: some View {
        switch message.role {
        case .user: Question(text: message.text)
        case .assistant: Answer(message: message, last: last, streaming: streaming)
        }
    }
}

private struct Question: View {
    let text: String
    @State private var pointer = Pointer()

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 90)
            Revealed(pointer: pointer) { CopyButton(text: text) }
            Text(text)
                .font(.system(size: MarkdownView.size))
                .lineSpacing(MarkdownView.leading)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .onHover { pointer.over = $0 }
    }
}

/// Whether the pointer is over a message, kept apart from the message so
/// only what shows on hover redraws when it changes.
@MainActor
@Observable
private final class Pointer {
    var over = false
}

/// Content shown while the pointer is over its message.
private struct Revealed<Content: View>: View {
    let pointer: Pointer
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().opacity(pointer.over ? 1 : 0).animation(Motion.hover, value: pointer.over)
    }
}

/// Copy, and ask again for the last answer: always there on the last,
/// on hover on the others.
private struct AnswerButtons: View {
    let text: String
    let last: Bool
    let retry: () -> Void
    let pointer: Pointer

    var body: some View {
        HStack(spacing: 2) {
            CopyButton(text: text)
            if last { RetryButton(act: retry) }
        }
        .padding(.leading, -7)
        .opacity(pointer.over || last ? 1 : 0)
        .animation(Motion.hover, value: pointer.over)
    }
}

private struct Answer: View {
    let message: Message
    let last: Bool
    /// Still arriving: its buttons wait until it's done.
    let streaming: Bool

    @Environment(\.chatActions) private var actions
    /// Read only by the buttons: the answer's own body doesn't redraw as the
    /// pointer comes and goes, which scrolling past does all the time.
    @State private var pointer = Pointer()
    @State private var thoughtsOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let author = message.author {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle").font(.system(size: 9.5, weight: .semibold))
                    Text(author).font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Palette.muted)
            }
            // Kept from draw to draw (hovering redraws this): it reads the whole
            // reply for links and matches them against every source.
            let rendered = RenderedReply.of(message, searched: searched)
            let (text, entries) = (rendered.text, rendered.entries)
            if message.steps.contains(where: { $0.kind == .task || $0.kind == .phase }) {
                ResearchProgress(steps: message.steps, live: streaming)
            } else if !message.steps.isEmpty {
                StepsSummary(steps: message.steps)
            }
            if !entries.isEmpty { SourcesStrip(entries: entries).padding(.bottom, 2) }
            if !message.reasoning.isEmpty { thoughts }
            if !text.isEmpty { ReplyText(text: text, cites: rendered.cites, reply: message.id, streaming: streaming) }
            if message.interrupted {
                Text("Stopped").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
            if !message.text.isEmpty, !streaming {
                AnswerButtons(text: message.text, last: last, retry: actions.retry, pointer: pointer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { pointer.over = $0 }
    }

    /// A reply that looked things up on the web, whose links are citations.
    private var searched: Bool { !message.sources.isEmpty || message.steps.contains { $0.kind != .tool } }

    /// The model's thinking, folded away unless asked for.
    private var thoughts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.settle) { thoughtsOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(message.text.isEmpty && !message.interrupted ? "Thinking" : "Thought it through")
                        .font(.system(size: 12.5))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(thoughtsOpen ? 90 : 0))
                }
                .foregroundStyle(Palette.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if thoughtsOpen {
                Text(message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Capsule().fill(Palette.hairline).frame(width: 2) }
                    .transition(.opacity)
            }
        }
    }
}

/// A reply's words: as it streams in, shown by a typewriter at a reader's
/// pace, each word fading in; the rest of the answer doesn't redraw as they
/// come, since only this reads the typewriter.
private struct ReplyText: View {
    let text: String
    let cites: [String: String]
    let reply: UUID
    let streaming: Bool
    @State private var typewriter = Typewriter()

    var body: some View {
        let shown = typewriter.busy || streaming ? typewriter.shown : text
        MarkdownView(
            text: shown, cites: cites, reply: reply,
            tail: typewriter.busy || streaming ? MarkdownView.Tail(fresh: typewriter.fresh) : nil
        )
        .equatable()
        .onAppear { typewriter.follow(text, finished: !streaming) }
        .onChange(of: text) { _, text in typewriter.follow(text, finished: !streaming) }
        .onChange(of: streaming) { _, streaming in typewriter.follow(text, finished: !streaming) }
    }
}

private struct RetryButton: View {
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink.opacity(0.8) : Palette.muted)
                .frame(width: 26, height: 22)
                .background(hovering ? Palette.veil : .clear, in: Rounded.row)
                .contentShape(Rounded.row)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Ask again")
        .accessibilityLabel("Ask again")
        .animation(Motion.hover, value: hovering)
    }
}

// MARK: - Status

/// Under the last message: that the model is thinking or busy, or why the
/// reply failed and what to do about it.
/// Where the chat was summarised: the messages above are sent as the
/// summary from here on. Opens to show it.
private struct SummaryDivider: View {
    let summary: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.quick) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                    Label("Earlier messages summarised", systemImage: open ? "chevron.down" : "chevron.right")
                        .font(TextStyle.secondary.font).foregroundStyle(Palette.muted).fixedSize()
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                }
            }
            .buttonStyle(.plain)
            if open {
                Text(summary).font(TextStyle.secondary.font).foregroundStyle(Palette.muted).textSelection(.enabled)
                    .transition(.opacity)
            }
        }
    }
}

private struct Status: View {
    let browser: Browser
    let conversation: Conversation
    let retry: () -> Void
    @ObservedObject private var ledger = AssistantLedger.shared

    var body: some View {
        Group {
            switch conversation.phase {
            case .waiting where researching, .answering where researching:
                // The research card above shows its own progress; the time and tokens go here.
                TurnMeta(prefs: browser.prefs, conversation: conversation)
            case .waiting:
                if let activity = conversation.activities.last(where: { !$0.done }) {
                    Working(title: activity.title, prefs: browser.prefs, conversation: conversation)
                } else {
                    Working(title: waitingWords, prefs: browser.prefs, conversation: conversation, wanders: true)
                }
            case .answering:
                if let activity = conversation.activities.last(where: { !$0.done }) {
                    Working(title: activity.title, prefs: browser.prefs, conversation: conversation)
                } else if conversation.messages.last?.text.isEmpty != false {
                    Working(title: "Thinking", prefs: browser.prefs, conversation: conversation, wanders: true)
                } else {
                    TurnMeta(prefs: browser.prefs, conversation: conversation)
                }
            case .failed(let reason):
                Failure(reason: reason, retry: retry) { browser.openSettings(at: .ai) }
            case .idle:
                // What the last reply did, put back in one go.
                let done = ledger.latest(in: conversation.id)
                if !done.isEmpty {
                    Button {
                        Task { _ = await ledger.undo(done.map(\.id), in: conversation.id) }
                    } label: {
                        Label(
                            done.count == 1 ? "Undo what it did" : "Undo the \(done.count) things it did",
                            systemImage: "arrow.uturn.backward"
                        )
                        .font(.system(size: 12.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.muted)
                    .help(done.map(\.what).joined(separator: "\n"))
                }
            }
        }
        .transition(.opacity)
        .animation(Motion.quick, value: conversation.phase)
    }

    private var researching: Bool {
        conversation.messages.last?.steps.contains { $0.kind == .phase } == true && conversation.messages.last?.text.isEmpty != false
    }

    private var waitingWords: String {
        conversation.messages.last?.reasoning.isEmpty == false ? "Thinking" : "Asking \(Assistant.shared.provider.name)"
    }
}

/// A line of shimmering words while waiting: what it's doing, or, with
/// nothing more to say (`wanders`), a word that changes every few seconds;
/// after a while how long the turn has taken, and with Settings › AI › Show
/// token count, what it has spent so far.
private struct Working: View {
    let title: String
    @ObservedObject var prefs: Preferences
    let conversation: Conversation
    var wanders = false
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { time in
            let spent = time.date.timeIntervalSince(conversation.askedAt ?? time.date)
            HStack(spacing: 7) {
                Image(systemName: "sparkle").font(.system(size: 10, weight: .semibold))
                Text(words(after: spent) + "…").font(.system(size: 13)).contentTransition(.opacity)
                    .animation(Motion.quick, value: words(after: spent))
                TurnMeta.Line(prefs: prefs, conversation: conversation, seconds: spent)
            }
        }
        .foregroundStyle(Palette.muted)
        .overlay {
            if !still {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Palette.ground.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: sweep ? geo.size.width : -geo.size.width * 0.5)
                }
                .allowsHitTesting(false)
            }
        }
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { sweep = true }
        }
        .accessibilityElement(children: .combine)
    }
}

extension Working {
    /// The provider's name first, then a word of Mote's every few seconds.
    private func words(after seconds: TimeInterval) -> String {
        guard wanders, seconds >= 3 else { return title }
        let start = conversation.askedAt.map { Int($0.timeIntervalSinceReferenceDate) } ?? 0
        return Self.verbs[(start + Int(seconds / 3)) % Self.verbs.count]
    }

    static let verbs = [
        "Browsing", "Pondering", "Rummaging", "Sifting", "Weaving", "Tinkering", "Mulling", "Puzzling", "Sketching", "Scouting",
        "Tracing", "Untangling", "Brewing", "Combing through", "Charting", "Wandering", "Noodling", "Assembling", "Considering",
        "Distilling", "Fathoming", "Gathering", "Hatching", "Imagining", "Juggling", "Kneading", "Lining up", "Musing", "Nudging",
        "Orienting", "Piecing together", "Quilting", "Reckoning", "Shaping", "Threading", "Unfolding", "Venturing", "Whittling",
        "Zeroing in", "Spelunking",
    ]
}

/// How long the turn has taken, once it's been a while, and what it has
/// spent so far (Settings › AI › Show token count), rising as it goes.
private struct TurnMeta: View {
    @ObservedObject var prefs: Preferences
    let conversation: Conversation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { time in
            Line(prefs: prefs, conversation: conversation, seconds: time.date.timeIntervalSince(conversation.askedAt ?? time.date))
                .foregroundStyle(Palette.muted)
        }
    }

    struct Line: View {
        @ObservedObject var prefs: Preferences
        let conversation: Conversation
        let seconds: TimeInterval

        var body: some View {
            let spent = prefs.showsTokens ? conversation.spentSoFar.map(withWriting) : nil
            if seconds >= 10 || spent != nil {
                HStack(spacing: 6) {
                    if seconds >= 10 { Text(Self.time(seconds)) }
                    if let spent {
                        Text("↑\(tokens(spent.input)) ↓\(tokens(spent.output))").contentTransition(.numericText())
                            .animation(Motion.quick, value: spent.input + spent.output)
                    }
                }
                .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Palette.faint)
                .help(spent.map { spentLine($0) } ?? "")
            }
        }

        /// Words out are only counted when a call ends: until then, about
        /// four characters a token of what has been written so far.
        private func withWriting(_ spent: Usage) -> Usage {
            guard let last = conversation.messages.last, last.role == .assistant else { return spent }
            var guess = spent
            guess.output = max(spent.output, (last.text.count + last.reasoning.count) / 4)
            return guess
        }

        /// 42s, 3m 05s, 1h 02m.
        static func time(_ seconds: TimeInterval) -> String {
            let whole = Int(seconds)
            if whole < 60 { return "\(whole)s" }
            if whole < 3600 { return "\(whole / 60)m \(String(format: "%02d", whole % 60))s" }
            return "\(whole / 3600)h \(String(format: "%02d", whole / 60 % 60))m"
        }
    }
}

private struct Failure: View {
    let reason: String
    let retry: () -> Void
    let settings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.unsafe)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 9) {
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Pill("Try Again", filled: true, action: retry)
                    Pill("AI Settings…", action: settings)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.wash.opacity(0.55), in: Rounded.card)
        .overlay(Rounded.card.strokeBorder(Palette.hairline))
    }
}

private struct JumpDown: View {
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink.opacity(hovering ? 0.9 : 0.7))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.ground).shadow(color: .black.opacity(0.12), radius: 8, y: 3))
                .overlay(Circle().strokeBorder(Palette.hairline))
                .contentShape(Circle())
        }
        .buttonStyle(Pressed())
        .onHover { hovering = $0 }
        .help("Go to the latest")
        .accessibilityLabel("Go to the latest")
    }
}

// MARK: - Composer

/// The next message, and who it goes to, in the same rounded box as the new
/// tab's composer. While a reply comes, the send button stops it. A mention
/// being typed with @ opens a quiet picker of the window's other tabs above
/// the field; choosing one shares that tab with the chat. A `/` typed first
/// opens the same kind of picker for the built-in skills, whose prompt fills
/// the field.
private struct ChatComposer: View {
    let browser: Browser
    let conversation: Conversation
    @Binding var draft: String
    @Binding var height: CGFloat
    let focus: Int
    /// The other tabs the @-picker offers, and what to do when one is chosen.
    /// Asked for only when the @ picker shows.
    let mentionables: () -> [MentionMenu.Candidate]
    let choseMention: (MentionMenu.Candidate) -> Void
    let send: () -> Void
    @State private var selection = ComposerSelection()
    @State private var dismissedMenu: ComposerMenu?
    @State private var escapePick: Int?

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Which picker the draft calls for: the `/` skills, the `@` mentions, or
    /// none. The two never argue, so a leading slash is a skill and a slash
    /// anywhere else is literal.
    private var menu: ComposerMenu { ComposerMenu.of(draft) }

    /// The skills the command being typed offers, if one is.
    private var skills: [Skill.Item] {
        guard let query = Skill.query(in: draft) else { return [] }
        return Skill.matching(query)
    }

    /// The tabs the mention being typed offers, if one is.
    private var matches: [MentionMenu.Candidate] {
        guard menu == .mentions, let query = MentionMenu.query(in: draft) else { return [] }
        return MentionMenu.matching(query, in: mentionables())
    }

    private var pickerItems: [ComposerPickerItem] {
        switch menu {
        case .skills: skills.map(ComposerPickerItem.skill)
        case .mentions: matches.map(ComposerPickerItem.mention)
        case .none: []
        }
    }

    private var pickerVisible: Bool { !pickerItems.isEmpty && dismissedMenu != menu }

    /// Return picks the first offered row while a picker is up, and sends the
    /// message otherwise. A finished `/command` with text after it is expanded
    /// into its prompt and sent.
    private func submit() {
        if pickerVisible, confirmSelection() { return }
        if let expanded = Skill.expand(draft) {
            draft = expanded
            send()
        } else if !conversation.busy || hasText {
            send()
        }
    }

    @discardableResult
    private func confirmSelection() -> Bool {
        guard pickerVisible, let index = selection.confirmedIndex(count: pickerItems.count), pickerItems.indices.contains(index)
        else { return false }
        choose(pickerItems[index])
        return true
    }

    private func choose(_ item: ComposerPickerItem) {
        switch item {
        case .mention(let candidate):
            choseMention(candidate)
            draft = MentionMenu.cleared(draft)
        case .skill(let skill):
            draft = skill.prompt
        }
        dismissedMenu = nil
        selection.reset()
        releaseEscapePick()
        // One Mote runs itself (/usage, /compact, /new, /clear) runs as it's
        // picked: left as the draft, the picker would only offer it again.
        if case .skill(let skill) = item, skill.prompt.hasPrefix("/") { send() }
    }

    private func moveSelection(_ step: Int) -> Bool {
        guard pickerVisible else { return false }
        selection.move(step, count: pickerItems.count)
        return true
    }

    private func dismissPicker() {
        guard pickerVisible else { return }
        dismissedMenu = menu
        selection.reset()
        releaseEscapePick()
    }

    private func holdEscapePick() {
        guard pickerVisible, escapePick == nil, browser.field.picked == nil else { return }
        escapePick = -1
        browser.field.picked = -1
    }

    private func releaseEscapePick() {
        guard escapePick != nil else { return }
        escapePick = nil
        if browser.field.picked == -1 { browser.field.picked = nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if pickerVisible {
                ComposerPicker(items: pickerItems, highlighted: selection.highlightedIndex, choose: choose)
            }
            ChatInput(
                text: $draft, height: $height, placeholder: "Ask a follow-up", focus: focus,
                submit: submit,
                moveSelection: moveSelection,
                choose: { pickerVisible && confirmSelection() },
                escape: {
                    if pickerVisible {
                        dismissPicker()
                        return true
                    }
                    guard conversation.busy else { return false }
                    conversation.stop()
                    return true
                },
                backtab: {
                    guard browser.prefs.aiActs else { return false }
                    ChatModes.shared.toggle(conversation.id)
                    return true
                }
            )
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Ask a follow-up")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.ink.opacity(0.35))
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                ToolToggles()
                if browser.prefs.aiActs { ModeChip(chat: conversation.id) }
                Spacer(minLength: 0)
                AIChip(browser: browser)
                if conversation.busy, !hasText {
                    RoundButton(symbol: "stop.fill", filled: true, help: "Stop   esc") { conversation.stop() }
                } else {
                    RoundButton(
                        symbol: "arrow.up", filled: hasText, help: conversation.busy ? "Send after this reply   ↩" : "Send   ↩", act: send)
                }
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Palette.ground)
                .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.08), radius: 22, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1).allowsHitTesting(false)
        }
        .animation(Motion.quick, value: conversation.busy)
        .animation(Motion.quick, value: pickerItems)
        .onChange(of: draft) { _, _ in
            selection.reset()
            dismissedMenu = nil
        }
        .onChange(of: pickerItems) { _, _ in selection.reset() }
        .onChange(of: pickerVisible) { _, visible in
            if visible { holdEscapePick() } else { releaseEscapePick() }
        }
        .onChange(of: browser.field.picked) { oldValue, newValue in
            guard oldValue == escapePick, newValue == nil, pickerVisible else { return }
            escapePick = nil
            dismissedMenu = menu
            selection.reset()
        }
        .onDisappear { releaseEscapePick() }
    }
}

/// The composer's round button: send, or stop while a reply comes.
struct RoundButton: View {
    let symbol: String
    let filled: Bool
    let help: String
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "stop.fill" ? 10 : 13, weight: .semibold))
                .foregroundStyle(filled ? Palette.ground : Palette.muted)
                .frame(width: 30, height: 30)
                .background(Circle().fill(filled ? Palette.ink.opacity(hovering ? 0.8 : 1) : Palette.veil))
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(Pressed())
        .disabled(!filled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help.components(separatedBy: "   ")[0])
        .animation(Motion.quick, value: filled)
        .animation(Motion.hover, value: hovering)
    }
}

/// What an answer shows, worked out from its message once and kept until
/// the message changes: the text without a closing list of sources, the
/// sources to list, and the chip name for each cited page.
@MainActor
struct RenderedReply {
    let text: String
    let entries: [Citations.Entry]
    let cites: [String: String]

    private static var kept: [UUID: (key: [Int], reply: RenderedReply)] = [:]

    static func of(_ message: Message, searched: Bool) -> RenderedReply {
        // The text only grows while it streams, so its length tells versions apart.
        let key = [message.text.utf8.count, message.sources.count, searched ? 1 : 0]
        if let kept = kept[message.id], kept.key == key { return kept.reply }
        let text = searched ? Citations.shown(message.text) : message.text
        let entries = searched ? Citations.arrange(message.sources, for: text) : []
        let cites = Dictionary(
            entries.filter { $0.number != nil }.map { ($0.source.id, $0.source.brand) }, uniquingKeysWith: { first, _ in first })
        let reply = RenderedReply(text: text, entries: entries, cites: cites)
        if kept.count > 200 { kept.removeAll() }
        kept[message.id] = (key, reply)
        return reply
    }
}

/// How this chat acts: asks before acting in pages, goes ahead (Auto), or
/// only looks and plans (Plan). ⇧⇥ or a click moves it on, for this chat only.
private struct ModeChip: View {
    let chat: UUID
    @ObservedObject private var modes = ChatModes.shared

    var body: some View {
        let mode = modes.mode(of: chat)
        let lit = mode != .asks
        Button {
            modes.toggle(chat)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: Self.symbol(mode)).font(.system(size: 9, weight: .semibold))
                Text(Self.title(mode)).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(lit ? Color(nsColor: Glow.clay) : Palette.muted)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(lit ? Color(nsColor: Glow.clay).opacity(0.14) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(Self.help(mode))
        .animation(Motion.quick, value: mode)
    }

    private static func symbol(_ mode: ChatMode) -> String {
        switch mode {
        case .asks: "hand.raised"
        case .auto: "forward.fill"
        case .plan: "list.number"
        }
    }

    private static func title(_ mode: ChatMode) -> String {
        switch mode {
        case .asks: "Asks"
        case .auto: "Auto"
        case .plan: "Plan"
        }
    }

    private static func help(_ mode: ChatMode) -> String {
        switch mode {
        case .asks: "It asks before acting in pages. Switch this chat to Auto with ⇧⇥."
        case .auto: "Auto: it acts without asking, in this chat; Undo puts it back. Only deleting history still asks. Plan next with ⇧⇥."
        case .plan: "Plan: it only looks, then gives a plan to run. Back to Asks with ⇧⇥."
        }
    }
}

/// The composer's text, kept outside the chat view: only what reads it redraws.
@Observable
private final class Draft {
    var text = ""
}

/// Tokens as people read them: 1,234 or 12.3k.
private func tokens(_ count: Int) -> String {
    count < 10_000 ? count.formatted() : (Double(count) / 1000).formatted(.number.precision(.fractionLength(1))) + "k"
}

private func spentLine(_ spent: Usage) -> String {
    var line = "\(tokens(spent.input)) in · \(tokens(spent.output)) out"
    if let cost = spent.cost { line += " · " + cost.formatted(.currency(code: "USD").precision(.fractionLength(2...4))) }
    return line
}

/// /usage: the last reply's tokens and the whole chat's.
private struct UsageCard: View {
    let conversation: Conversation
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                row("Last reply", conversation.turnSpent)
                row("This chat", conversation.chatSpent)
                if conversation.chatSpent == nil {
                    Text("Nothing counted yet: some models don't say what they spent.").font(.system(size: 11.5)).foregroundStyle(
                        Palette.muted)
                }
            }
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Close")
        }
        .padding(12)
        // A card as the composer's others are (its picker, the page chip).
        .background(Palette.wash, in: Rounded.card)
        .overlay(Rounded.card.strokeBorder(Palette.hairline))
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    private func row(_ title: String, _ spent: Usage?) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
            Text(spent.map(spentLine) ?? "—").font(.system(size: 12.5)).foregroundStyle(Palette.muted).monospacedDigit()
        }
    }
}
