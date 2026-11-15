import MoteAI
import SwiftUI

/// What waits over the composer: a question the assistant asked, messages
/// queued behind the reply under way, and a plan ready to run.
struct ChatTray: View {
    let conversation: Conversation
    @ObservedObject private var modes = ChatModes.shared

    init(conversation: Conversation) {
        self.conversation = conversation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let question = conversation.question {
                QuestionCard(question: question, answer: conversation.answer)
            }
            ForEach(conversation.queued) { queued in
                QueuedRow(
                    queued: queued, busy: conversation.busy,
                    steer: { conversation.steer(queued.id) },
                    sendNow: { conversation.sendNow(queued.id) },
                    remove: { conversation.unqueue(queued.id) })
            }
            if plan {
                HStack(spacing: 8) {
                    Pill("Run plan", filled: true) {
                        modes.leavePlan(conversation.id)
                        Assistant.shared.ask("Go ahead with the plan.", in: conversation)
                    }
                    .help("Leaves Plan for how this chat acted before, and carries the plan out")
                    Text("or say what to change").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.quick, value: conversation.queued)
        .animation(Motion.quick, value: conversation.question)
    }

    /// The chat is in Plan and its last reply is a plan, done.
    private var plan: Bool {
        guard modes.mode(of: conversation.id) == .plan, !conversation.busy, conversation.question == nil,
            let last = conversation.messages.last
        else { return false }
        return last.role == .assistant && !last.text.isEmpty && !last.interrupted
    }
}

/// A message waiting for the reply under way: send it now (stopping the
/// reply), steer the reply with it, or let it go.
private struct QueuedRow: View {
    let queued: Conversation.Queued
    let busy: Bool
    let steer: () -> Void
    let sendNow: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: queued.steering ? "arrow.turn.down.right" : "clock")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text(queued.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if queued.steering {
                Text("At its next step").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            } else if busy {
                TrayLink("Steer", help: "Tells the reply under way at its next step, without stopping it", act: steer)
                TrayLink("Send now", help: "Stops the reply and sends this", act: sendNow)
            }
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(Pressed())
            .help("Don't send this")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.opacity.combined(with: .offset(y: 4)))
    }
}

/// The assistant's question, with its choices; typing in the composer and
/// sending answers it too.
private struct QuestionCard: View {
    let question: Conversation.Question
    let answer: (String?) -> Void
    @State private var picked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "questionmark.bubble").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                Text(question.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let place = question.place {
                    Text(place).font(.system(size: 11)).foregroundStyle(Palette.muted).monospacedDigit()
                }
                Button {
                    answer(nil)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(Pressed())
                .help("Don't answer")
            }
            ForEach(question.options, id: \.label) { option in
                OptionRow(option: option, several: question.several, on: picked.contains(option.label)) {
                    if question.several {
                        if picked.contains(option.label) { picked.remove(option.label) } else { picked.insert(option.label) }
                    } else {
                        answer(option.label)
                    }
                }
            }
            HStack(spacing: 8) {
                if question.several {
                    Pill("Answer", filled: !picked.isEmpty) {
                        guard !picked.isEmpty else { return }
                        answer(question.options.map(\.label).filter(picked.contains).joined(separator: ", "))
                    }
                }
                Text("Or type your own answer below").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
        }
        .padding(12)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(.opacity.combined(with: .offset(y: 4)))
        .onChange(of: question) { _, _ in picked = [] }
    }
}

private struct OptionRow: View {
    let option: Conversation.Question.Option
    let several: Bool
    let on: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if several {
                    Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink.opacity(0.9))
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(hovering || on ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct TrayLink: View {
    let title: String
    let help: String
    let act: () -> Void
    @State private var hovering = false

    init(_ title: String, help: String, act: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.act = act
    }

    var body: some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
