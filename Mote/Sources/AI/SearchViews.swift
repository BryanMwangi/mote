import AppKit
import MoteAI
import SwiftUI

/// A research's progress, then its record: the stages and the parts
/// researched, each with how many searches and pages it took.
struct ResearchProgress: View {
    let steps: [Activity]
    /// Still researching: shown open, with what's under way.
    let live: Bool
    @State private var open: Bool?

    private var parts: [Activity] { steps.filter { $0.kind == .task } }
    private var stages: [Activity] { steps.filter { $0.kind == .phase } }
    private func count(_ kind: Activity.Kind, in id: String? = nil) -> Int {
        steps.filter { step in step.kind == kind && (id.map { step.id.hasPrefix($0 + "-") } ?? true) }.count
    }

    var body: some View {
        let showing = open ?? live
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Motion.settle) { open = !showing }
            } label: {
                HStack(spacing: 6) {
                    if live { Ring(size: 10) } else { Image(systemName: "text.magnifyingglass").font(.system(size: 11, weight: .medium)) }
                    Text(headline).font(.system(size: 12.5, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(showing ? 90 : 0))
                }
                .foregroundStyle(Palette.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showing {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(rows, id: \.id) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            mark(for: row).frame(width: 14)
                            Text(row.title)
                                .font(.system(size: 12.5, weight: row.kind == .phase ? .medium : .regular))
                                .foregroundStyle(row.kind == .phase ? Palette.muted : Palette.ink.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if row.kind == .task { tally(for: row) }
                        }
                    }
                    if live {
                        Text("Research takes a few minutes. You can keep browsing meanwhile.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.faint)
                            .padding(.top, 2)
                    }
                }
                .padding(12)
                .background(Palette.wash.opacity(0.45), in: Rounded.card)
                .overlay(Rounded.card.strokeBorder(Palette.hairline))
                .transition(.opacity)
            }
        }
    }

    /// Stages and parts in the order they came: planning, the parts, the
    /// review with its follow-ups, the writing.
    private var rows: [Activity] { steps.filter { $0.kind == .phase || $0.kind == .task } }

    private var headline: String {
        let searches = count(.search)
        let pages = count(.read)
        let done = parts.filter(\.done).count
        if live {
            let stage = stages.last(where: { !$0.done })?.title ?? "Researching"
            return parts.isEmpty
                ? stage
                : "\(stage == "Planning the research" ? "Researching" : stage) · \(done) of \(parts.count) parts · \(searches) searches"
        }
        return "Researched \(parts.count) parts · \(searches) searches · \(pages) pages"
    }

    /// How many searches and pages a part took, as small counted symbols.
    @ViewBuilder
    private func tally(for part: Activity) -> some View {
        let searches = count(.search, in: part.id)
        let pages = count(.read, in: part.id)
        HStack(spacing: 8) {
            if searches > 0 { counted(searches, "magnifyingglass") }
            if pages > 0 { counted(pages, "doc.text") }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Palette.muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(searches) searches, \(pages) pages")
    }

    private func counted(_ number: Int, _ symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .medium))
            Text("\(number)")
        }
    }

    /// Done, under way, waiting its turn, or left undone when stopped.
    @ViewBuilder
    private func mark(for row: Activity) -> some View {
        if row.done {
            Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Palette.muted)
        } else if live, row.kind == .phase || steps.contains(where: { $0.id.hasPrefix(row.id + "-") }) {
            Ring(size: 9)
        } else if live {
            Circle().strokeBorder(Palette.faint, lineWidth: 1.2).frame(width: 9, height: 9)
        } else {
            Image(systemName: "minus").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Palette.faint)
        }
    }
}

/// The sub-agents a reply started: each on a row with what it's doing now,
/// how many tools it has used and the tokens it has spent, opening to its
/// own steps.
struct AgentsCard: View {
    /// The agents and their own steps, in the order they came.
    let steps: [Activity]

    /// A reply's steps: those of its sub-agents (each with its own), and the rest.
    static func split(_ steps: [Activity]) -> (agents: [Activity], others: [Activity]) {
        let agents = steps.filter { $0.kind == .agent }.map(\.id)
        let theirs = { (step: Activity) in agents.contains { step.id == $0 || step.id.hasPrefix($0 + "-") } }
        return (steps.filter(theirs), steps.filter { !theirs($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(steps.filter { $0.kind == .agent }, id: \.id) { agent in
                AgentRow(agent: agent, tools: steps.filter { $0.id.hasPrefix(agent.id + "-") })
            }
        }
        .padding(12)
        .background(Palette.wash.opacity(0.45), in: Rounded.card)
        .overlay(Rounded.card.strokeBorder(Palette.hairline))
    }
}

private struct AgentRow: View {
    let agent: Activity
    let tools: [Activity]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.settle) { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    mark.frame(width: 14)
                    Text(agent.title).font(.system(size: 12.5)).foregroundStyle(Palette.ink.opacity(0.85)).lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(tally).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.muted)
                        .contentTransition(.numericText()).animation(Motion.quick, value: tally)
                    Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Palette.muted)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // What it's doing now, or how it ended.
            if let now = agent.done ? agent.detail : tools.last(where: { !$0.done })?.title ?? agent.detail {
                Text(agent.done ? now : now + "…").font(.system(size: 11.5)).foregroundStyle(Palette.faint).lineLimit(1)
                    .padding(.leading, 22).contentTransition(.opacity).animation(Motion.quick, value: now)
            }
            if open {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(tools, id: \.id) { StepLine(step: $0) }
                }
                .padding(.leading, 22)
                .transition(.opacity)
            }
        }
    }

    private var tally: String {
        let used = "\(tools.count) tool\(tools.count == 1 ? "" : "s")"
        return agent.spent.map { used + " · " + tokens($0) + " tokens" } ?? used
    }

    @ViewBuilder
    private var mark: some View {
        if !agent.done {
            Ring(size: 9)
        } else if agent.outcome == .failed {
            Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Palette.muted)
        }
    }
}

/// What a search reply did: a line saying how many searches and pages,
/// opening to the list of them.
struct StepsSummary: View {
    let steps: [Activity]
    @State private var open = false

    var body: some View {
        let searches = steps.filter { $0.kind == .search }.count
        let reads = steps.filter { $0.kind == .read }.count
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.settle) { open.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(summary(searches: searches, reads: reads)).font(.system(size: 12.5))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .foregroundStyle(Palette.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(steps, id: \.id) { step in StepLine(step: step) }
                }
                .padding(.leading, 2)
                .transition(.opacity)
            }
        }
        // What went wrong shows without asking.
        .onAppear { if steps.contains(where: { $0.outcome != nil && $0.outcome != .done }) { open = true } }
    }

    private func summary(searches: Int, reads: Int) -> String {
        var parts: [String] = []
        if searches > 0 { parts.append(searches == 1 ? "Searched once" : "Searched \(searches) times") }
        if reads > 0 { parts.append(reads == 1 ? "read 1 page" : "read \(reads) pages") }
        if parts.isEmpty { parts.append(steps.count == 1 ? "Used 1 tool" : "Used \(steps.count) tools") }
        let count = { (outcome: Activity.Outcome) in steps.filter { $0.outcome == outcome }.count }
        if count(.failed) > 0 { parts.append("\(count(.failed)) failed") }
        if count(.refused) > 0 { parts.append("\(count(.refused)) not allowed") }
        if count(.interrupted) > 0 { parts.append("\(count(.interrupted)) cut short") }
        let line = parts.joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }
}

/// A step, with how it went and what it came to: "Closed “GitHub”, “Hacker News”".
struct StepLine: View {
    let step: Activity
    @State private var whole = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: mark)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title + (label.map { " · " + $0 } ?? "")).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                if let detail = step.detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.faint).lineLimit(whole ? nil : 2).textSelection(.enabled)
                        .onTapGesture { whole.toggle() }
                }
            }
        }
        .foregroundStyle(Palette.muted)
    }

    private var mark: String {
        switch step.outcome {
        case .failed: "xmark.circle"
        case .refused: "hand.raised"
        case .interrupted: "pause.circle"
        default: step.kind == .search ? "magnifyingglass" : step.kind == .read ? "doc.text" : "checkmark.circle"
        }
    }

    private var tint: Color {
        switch step.outcome {
        case .failed: .red
        case .refused, .interrupted: .orange
        default: Palette.muted
        }
    }

    private var label: String? {
        switch step.outcome {
        case .failed: "failed"
        case .refused: "not allowed"
        case .interrupted: "cut short"
        default: nil
        }
    }
}

/// The pages a reply drew on, side by side above it: those it cites first,
/// numbered as in the text.
struct SourcesStrip: View {
    let entries: [Citations.Entry]
    @State private var all = false

    /// Uncited pages shown before the rest fold into a count: a research
    /// can read hundreds, and a card each would be more than anyone reads.
    static let uncited = 6

    var body: some View {
        let cited = entries.filter { $0.number != nil }
        let rest = entries.filter { $0.number == nil }
        let shown = all ? entries : cited + rest.prefix(Self.uncited)
        let hidden = entries.count - shown.count
        ScrollView(.horizontal, showsIndicators: false) {
            // Lazy, so only the cards in view are made.
            LazyHStack(spacing: 8) {
                ForEach(shown, id: \.source.id) { entry in
                    SourceCard(entry: entry)
                }
                if hidden > 0 {
                    MoreCard(count: hidden) { all = true }
                }
            }
            .padding(.vertical, 1)
        }
        .frame(height: 68)
        .scrollClipDisabled()
    }
}

/// The pages folded away, as a card that shows them.
private struct MoreCard: View {
    let count: Int
    let show: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: show) {
            VStack(alignment: .leading, spacing: 4) {
                Text("+\(count)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.8))
                Text(count == 1 ? "more page read" : "more pages read").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 12)
            .frame(width: 120, height: 66, alignment: .leading)
            .background(hovering ? Palette.hover : Palette.wash.opacity(0.4), in: Rounded.row)
            .overlay(Rounded.row.strokeBorder(Palette.hairline))
            .contentShape(Rounded.row)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Show \(count) more sources")
    }
}

private struct SourceCard: View {
    let entry: Citations.Entry
    @State private var hovering = false
    @State private var icon: NSImage?
    @Environment(\.openURL) private var openURL

    var body: some View {
        let source = entry.source
        Button {
            openURL(source.url)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Mark(icon: icon, letter: String(source.site.prefix(1)).uppercased(), size: 14)
                    Text(source.site).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                    Spacer(minLength: 0)
                    if let number = entry.number {
                        Text("\(number)").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.muted)
                    }
                }
                Text(source.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 176, height: 66, alignment: .topLeading)
            .background(hovering ? Palette.hover : Palette.wash.opacity(0.6), in: Rounded.row)
            .overlay(Rounded.row.strokeBorder(entry.number == nil ? Palette.hairline : Palette.edge))
            .opacity(entry.number == nil ? 0.8 : 1)
            .contentShape(Rounded.row)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(source.snippet.map { "\(source.name)\n\n\($0)" } ?? "\(source.name)\n\(source.url.absoluteString)")
        .accessibilityLabel(entry.number.map { "Source \($0), \(source.site): \(source.name)" } ?? "Source \(source.site): \(source.name)")
        .animation(Motion.hover, value: hovering)
        .task(id: source.site) { icon = await Favicons.shared.icon(for: source.url.host()?.lowercased() ?? source.site) }
    }
}
