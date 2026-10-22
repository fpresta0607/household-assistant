// What a connector is for, named over the top of the connector's own page.

import Foundation

enum ConnectorCategory: String, Codable, CaseIterable, Sendable {
    case money
    case faith
    case calendarAndMail = "calendar-and-mail"
    case notes
    case web
    case picturesAndVideo = "pictures-and-video"
    case everyday

    var title: String {
        switch self {
        case .money:
            return "Money"
        case .faith:
            return "Faith"
        case .calendarAndMail:
            return "Calendar and mail"
        case .notes:
            return "Notes"
        case .web:
            return "The web"
        case .picturesAndVideo:
            return "Pictures and video"
        case .everyday:
            return "Everyday"
        }
    }
}
