// The small pill above an assistant's bubble that names the skill that answered: a book
// for scripture, a microphone for sermons, the pig for PocketPiggies, a calendar, a list
// and a globe, each family in its own hue of the rainbow.

import SwiftUI

struct SkillBadge: View {
    let skill: CardSkill

    var body: some View {
        HStack(spacing: 5) {
            if skill == .pocketpiggies {
                PiggyMark()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
            }
            Text(skill.title)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(ink)
        .padding(.leading, 6)
        .padding(.trailing, 9)
        .padding(.vertical, 3)
        .background(background, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("From \(skill.title)")
    }

    private var symbol: String {
        switch skill {
        case .scripture:
            return "book.closed.fill"
        case .sermons:
            return "mic.fill"
        case .pocketpiggies:
            return "banknote"
        case .calendar:
            return "calendar"
        case .lists:
            return "checklist"
        case .web:
            return "globe"
        }
    }

    private var ink: Color {
        switch skill {
        case .scripture:
            return CardStyle.goldInk
        case .sermons:
            return CardStyle.wine
        case .pocketpiggies:
            return PocketPiggiesTheme.ink
        case .calendar:
            return CardStyle.accent
        case .lists:
            return CardStyle.listsInk
        case .web:
            return CardStyle.searchInk
        }
    }

    private var background: AnyShapeStyle {
        switch skill {
        case .scripture:
            return AnyShapeStyle(CardStyle.gold.opacity(0.22))
        case .sermons:
            return AnyShapeStyle(CardStyle.wine.opacity(0.1))
        case .pocketpiggies:
            return AnyShapeStyle(PocketPiggiesTheme.rainbow.opacity(0.2))
        case .calendar:
            return AnyShapeStyle(CardStyle.accent.opacity(0.12))
        case .lists:
            return AnyShapeStyle(CardStyle.listsGreen.opacity(0.14))
        case .web:
            return AnyShapeStyle(CardStyle.searchTeal.opacity(0.15))
        }
    }
}
