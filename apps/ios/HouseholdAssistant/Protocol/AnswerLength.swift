// How long the assistant's answers run, its own row on the assistant's page.

import Foundation

enum AnswerLength: String, Codable, CaseIterable, Sendable {
    case short, balanced, detailed

    var label: String {
        switch self {
        case .short:
            return "Short"
        case .balanced:
            return "Balanced"
        case .detailed:
            return "Detailed"
        }
    }
}
