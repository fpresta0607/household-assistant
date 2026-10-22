// The family room's shared look, the same on both phones, which either person changes on
// the room's page (household-app's family-look.js): the colour of the ring round the room's
// face, nil for its own white edge, and its appearance, Auto, where each phone draws the
// room on its own chat background, or Custom, one background for everyone. Custom keeps
// the latest custom background whoever chose it, so Auto and back to Custom shows it again.
//
// Each change is a line in the room, with who made it and when (FamilyLookLine).

import Foundation

struct FamilyLook: Decodable, Equatable, Sendable {
    enum Appearance: String, CaseIterable, Sendable {
        case auto, custom

        var label: String {
            switch self {
            case .auto:
                return "Auto"
            case .custom:
                return "Custom"
            }
        }
    }

    var ring: RingColor?
    var appearance: Appearance
    /// The latest custom background, kept while the room is on Auto.
    var background: ChatBackground?

    /// The look before anyone has changed it.
    static let standard = FamilyLook(ring: nil, appearance: .auto, background: nil)

    /// The backgrounds a phone can draw for everyone: its own photo is not shared.
    static let backgrounds: [ChatBackground] = [.rainbow, .dawn, .night]

    init(ring: RingColor?, appearance: Appearance, background: ChatBackground?) {
        self.ring = ring
        self.appearance = appearance
        self.background = background
    }

    /// A part a later gateway spells in a way this version cannot read is left as it
    /// stands, rather than failing the page.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ring = try? container.decodeIfPresent(RingColor.self, forKey: .ring)
        appearance = (try? container.decodeIfPresent(String.self, forKey: .appearance)).flatMap(Appearance.init(rawValue:)) ?? .auto
        background = (try? container.decodeIfPresent(String.self, forKey: .background))
            .flatMap(ChatBackground.init(rawValue:))
            .flatMap { Self.backgrounds.contains($0) ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey {
        case ring, appearance, background
    }

    /// The background the room is drawn on for everyone, nil while each phone draws its own.
    var sharedBackground: ChatBackground? {
        appearance == .custom ? background ?? .rainbow : nil
    }
}

/// One change to the family room's look, as the phone sends it and as each line says it.
enum FamilyLookChange: Equatable, Sendable {
    case photo
    /// Nil is the room's own white edge again.
    case color(RingColor?)
    /// Custom's background, nil to keep the latest one.
    case appearance(FamilyLook.Appearance, background: ChatBackground?)
}

/// A change to the family room's look as the room shows it: a line with its time.
struct FamilyLookLine: Equatable, Sendable, Identifiable {
    let id: String
    /// The person who made it.
    let author: String
    let sentAt: Date
    let rev: Int
    let change: FamilyLookChange

    /// "Franco changed the group color".
    func words(by name: String) -> String {
        switch change {
        case .photo:
            return "\(name) changed the group photo"
        case .color(nil):
            return "\(name) set the group color back to white"
        case .color:
            return "\(name) changed the group color"
        case .appearance(.auto, _):
            return "\(name) set the group's appearance to Auto"
        case .appearance(.custom, let background?):
            return "\(name) changed the group's background to \(background.label)"
        case .appearance(.custom, nil):
            return "\(name) set the group's appearance to Custom"
        }
    }
}
