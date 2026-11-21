import MoteAI
import SwiftUI

/// A compact, keyboard-highlightable row offered by either composer picker.
enum ComposerPickerItem: Identifiable, Equatable {
    case mention(MentionMenu.Candidate)
    case skill(Skill.Item)

    var id: String {
        switch self {
        case .mention(let candidate): "mention:\(candidate.id)"
        case .skill(let skill): "skill:\(skill.id)"
        }
    }

    var title: String {
        switch self {
        case .mention(let candidate): candidate.title
        case .skill(let skill): skill.typed
        }
    }

    var detail: String? {
        switch self {
        case .mention(let candidate): candidate.host.isEmpty ? nil : candidate.host
        case .skill(let skill): skill.title
        }
    }

    var symbol: String {
        switch self {
        case .mention: "globe"
        case .skill: "command"
        }
    }

    var accessibilityName: String {
        switch self {
        case .mention(let candidate): "Mention \(candidate.title)"
        case .skill(let skill): "\(skill.typed): \(skill.title)"
        }
    }

    var help: String {
        switch self {
        case .mention(let candidate): "Mention \(candidate.title)"
        case .skill(let skill): skill.prompt
        }
    }
}

/// The same bounded-height, scrollable Palette list for skills and mentioned tabs.
struct ComposerPicker: View {
    let items: [ComposerPickerItem]
    let highlighted: Int?
    let choose: (ComposerPickerItem) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            // Scrolls past six, with no bar.
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            choose(item)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Palette.muted)
                                    .frame(width: 14)
                                Text(item.title)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Palette.ink.opacity(0.85))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                if let detail = item.detail {
                                    Text(detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.muted)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            // The arrows' pick, plainly above the card's own wash.
                            .background(highlighted == index ? Palette.ink.opacity(0.12) : .clear, in: Rounded.row)
                            .contentShape(Rounded.row)
                        }
                        .buttonStyle(.plain)
                        .help(item.help)
                        .accessibilityLabel(item.accessibilityName)
                    }
                }
                .padding(.vertical, 3)
            }
            // Six rows tall at most; fewer, as tall as they are.
            .frame(height: CGFloat(min(items.count, 6)) * 28 + 6)
            .onChange(of: highlighted) { _, index in
                guard let index, items.indices.contains(index) else { return }
                // By the item's own id, which is the row's: an id by place kept
                // a row's old command showing as the list narrowed.
                withAnimation(Motion.quick) { proxy.scrollTo(items[index].id, anchor: .center) }
            }
            .background(Palette.wash, in: Rounded.card)
            .overlay(Rounded.card.strokeBorder(Palette.hairline))
            .transition(.opacity.combined(with: .offset(y: 4)))
        }
    }
}
