// What else this iPhone lets Steward AI use, beside the three the first run asks for
// (PermissionKind): Contacts, adding to Photos, the camera, and Face ID for App Lock. iOS
// asks about each the first time it is used, and only iOS changes them, on Steward AI's
// page in the iPhone's Settings. Settings shows where each stands as iOS has it, read
// again every time the app comes back (Permissions).

import Foundation

enum PhoneAccess: String, CaseIterable, Identifiable, Sendable {
    case contacts, photos, camera, faceID

    var id: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .contacts:
            return "person.crop.circle.fill"
        case .photos:
            return "photo.on.rectangle"
        case .camera:
            return "camera.fill"
        case .faceID:
            return "faceid"
        }
    }

    var title: String {
        switch self {
        case .contacts:
            return "Contacts"
        case .photos:
            return "Adding to Photos"
        case .camera:
            return "Camera"
        case .faceID:
            return "Face ID"
        }
    }
}

/// Where one of them stands as iOS has it, in the app's own words.
enum PhoneAccessState: Equatable, Sendable {
    case notAsked
    case allowed
    /// Some of it: Contacts the person picked.
    case limited
    case denied
    /// Not set up on this iPhone, such as Face ID with no face or no passcode at all.
    case unavailable

    var label: String {
        switch self {
        case .notAsked:
            return "Not asked"
        case .allowed:
            return "On"
        case .limited:
            return "Limited"
        case .denied:
            return "Off"
        case .unavailable:
            return "Not set up"
        }
    }

    /// Whether only iOS can turn it on now, on Steward AI's page in its Settings.
    var isUpToIOS: Bool {
        self == .denied || self == .unavailable
    }
}
