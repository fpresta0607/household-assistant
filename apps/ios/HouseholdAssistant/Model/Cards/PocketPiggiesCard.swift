// What PocketPiggies, the family's budgeting app, has to say, as one of four cards: the
// balance across the piggies, this month's budget, spending by category, or a savings
// goal. Amounts are in dollars.

import Foundation

enum PocketPiggiesCard: Equatable, Sendable {
    struct Piggy: Decodable, Equatable, Sendable {
        let name: String
        let balance: Double
    }

    struct Category: Decodable, Equatable, Sendable {
        let name: String
        let amount: Double
    }

    case balance(total: Double, piggies: [Piggy])
    case budget(month: String, spent: Double, limit: Double, daysLeft: Int?)
    case spending(title: String?, categories: [Category])
    case goal(name: String, saved: Double, target: Double, weekly: Double?)

    /// How full the budget meter or the goal ring is, from nothing to all of it.
    var progress: Double? {
        switch self {
        case .budget(_, let spent, let limit, _):
            return min(max(spent / limit, 0), 1)
        case .goal(_, let saved, let target, _):
            return min(max(saved / target, 0), 1)
        case .balance, .spending:
            return nil
        }
    }
}

extension PocketPiggiesCard: Decodable {
    private enum CodingKeys: String, CodingKey {
        case card, balance, piggies, month, spent, limit, daysLeft, title, categories, name, saved, target, weekly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .card) {
        case "balance":
            self = .balance(
                total: try container.decode(Double.self, forKey: .balance),
                piggies: try container.decodeIfPresent([Piggy].self, forKey: .piggies) ?? []
            )
        case "budget":
            let limit = try container.decode(Double.self, forKey: .limit)
            guard limit > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .limit, in: container, debugDescription: "a budget needs a limit")
            }
            self = .budget(
                month: try container.decode(String.self, forKey: .month),
                spent: try container.decode(Double.self, forKey: .spent),
                limit: limit,
                daysLeft: try container.decodeIfPresent(Int.self, forKey: .daysLeft)
            )
        case "spending":
            let categories = try container.decode([Category].self, forKey: .categories)
            guard !categories.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .categories, in: container, debugDescription: "spending needs its categories")
            }
            self = .spending(title: try container.decodeIfPresent(String.self, forKey: .title), categories: categories)
        case "goal":
            let target = try container.decode(Double.self, forKey: .target)
            guard target > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .target, in: container, debugDescription: "a goal needs a target")
            }
            self = .goal(
                name: try container.decode(String.self, forKey: .name),
                saved: try container.decode(Double.self, forKey: .saved),
                target: target,
                weekly: try container.decodeIfPresent(Double.self, forKey: .weekly)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .card, in: container, debugDescription: "not a PocketPiggies card this app draws")
        }
    }
}
