// The app's motion, in one place: Chats settling in as the app opens, what arrives in a
// thread fading in, the record button, typing dots, a message lifted for a reaction and a
// reaction popping on, the drawer springing out of the plus, follow-ups arriving in turn,
// a transcript unfolding, a picture coming into focus, a chart growing, a light gliding
// once across a button, and a switch or a setting's row springing to its value. With
// Reduce Motion on, every one of them becomes a plain fade or nothing.
//
// Everything a tap starts is a spring that settles in about a third of a second and can
// be caught mid-flight. Nothing runs while the app sits idle: no light circles a rim and
// no placeholder shimmers, since each of those redrew its view on every frame.
//
// A thread's rows never move or change size on a spring. The scroll view keeps the newest
// message in place as the thread grows, and a row still springing to its height made it
// correct its offset on every frame, so anything new in a thread fades in
// (`rowTransition`) and takes its size at once. A message this phone sends also rises from
// the composer, by a scale and an offset that change only its drawing, never its size.
//
// Reduce Motion is the app's own choice in Accessibility, which may follow the iPhone's
// or not, so every view reads `reducesMotion` rather than the iPhone's setting.

import SwiftUI

enum Motion {
    /// Something settling into place.
    static let arrive = Animation.spring(response: 0.3, dampingFraction: 0.84)
    /// The record button growing under the finger.
    static let press = Animation.spring(response: 0.25, dampingFraction: 0.7)
    /// A message rising out of the thread for reactions, a little bouncier than arriving.
    static let lift = Animation.spring(response: 0.32, dampingFraction: 0.72)
    /// The apps drawer springing out of the plus, a little past its size and back.
    static let springOut = Animation.spring(response: 0.32, dampingFraction: 0.68)
    /// A switch flipping, the glass lens sliding across a segmented control, and a
    /// setting's row springing back when its gateway refuses a change.
    static let flip = Animation.spring(response: 0.3, dampingFraction: 0.62)
    static let fade = Animation.easeOut(duration: 0.2)
    /// A picture or a card coming into focus once it is there.
    static let reveal = Animation.smooth(duration: 0.32)
    /// The six dots flying off a reaction as it lands.
    static let burst = Animation.easeOut(duration: 0.32)
    /// A chart's bar or a budget's line growing to its value, the next one `growStep` later.
    static let grow = Animation.spring(response: 0.3, dampingFraction: 0.78)
    static let growStep = Duration.milliseconds(40)
    /// A line chart drawing itself across.
    static let draw = Animation.smooth(duration: 0.34)
    /// The light sweeping across "Slide to cancel" while a note records, and only then.
    /// With Reduce Motion it stays still instead.
    static let shimmer = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: false)
    /// The light gliding once across the welcome's Get started, once the welcome has
    /// settled. With Reduce Motion it does not glide.
    static let glide = Animation.easeInOut(duration: 1.2)
    static let glideFirst = Duration.milliseconds(900)

    // MARK: The welcome

    /// How long the welcome plays as the app opens before it lifts away, while the app
    /// restores its local store and reconnects underneath (AppCover). Its mark has settled
    /// by then, and the light gliding across it is on its way out (WelcomeMark).
    static let welcomeLength = Duration.milliseconds(800)
    /// The welcome, or App Lock once it has opened, lifting away over the app.
    static let coverLeave = Animation.easeInOut(duration: 0.25)
    static let coverLeaveLength = Duration.milliseconds(250)

    // MARK: The entrance

    /// The page behind Chats settling in as the app opens.
    static let settle = Animation.smooth(duration: 0.3)
    /// How far apart the pins rise, and the Today card and the tab bar after them.
    static let entranceStep = 0.05

    /// The `index`th piece of Chats arriving as the app opens: the pins first, one after
    /// another, then the Today card, what was shared and the tab bar. All of it has landed in
    /// about a third of a second. With Reduce Motion it all fades in at once.
    static func entrance(_ index: Int, reduced: Bool) -> Animation {
        reduced ? fade : Animation.snappy(duration: 0.24).delay(entranceStep * Double(index))
    }

    static func arrive(reduced: Bool) -> Animation {
        reduced ? fade : arrive
    }

    static func press(reduced: Bool) -> Animation {
        reduced ? fade : press
    }

    static func lift(reduced: Bool) -> Animation {
        reduced ? fade : lift
    }

    static func springOut(reduced: Bool) -> Animation {
        reduced ? fade : springOut
    }

    static func flip(reduced: Bool) -> Animation {
        reduced ? fade : flip
    }

    static func reveal(reduced: Bool) -> Animation {
        reduced ? fade : reveal
    }

    /// The `index`th of several arriving one after another, `step` seconds apart, the
    /// first after `delay`: the follow-ups under an answer, the rows of the apps drawer.
    /// With Reduce Motion they all fade in at once.
    static func inTurn(_ index: Int, delay: Double = 0, step: Double, reduced: Bool) -> Animation {
        reduced ? fade : arrive.delay(delay + step * Double(index))
    }

    /// How anything new in a conversation's thread enters: a message, a typing bubble, a
    /// line of what the assistant did, and a card, a chip or a badge appearing in a bubble.
    /// It fades in over a fifth of a second and nothing else, with or without Reduce
    /// Motion, so no row moves or changes size on its way in. The fade travels with the
    /// transition, so it plays though nothing around it animates.
    static var rowTransition: AnyTransition {
        AnyTransition.opacity.animation(fade)
    }

    /// How a bubble enters Talk's thread and the widgets: up from below and growing, from
    /// the side it is said on.
    static func bubbleTransition(isOwn: Bool, reduced: Bool) -> AnyTransition {
        guard !reduced else {
            return .opacity
        }
        return .asymmetric(insertion: rise(from: isOwn ? .bottomTrailing : .bottomLeading), removal: .opacity)
    }

    /// Something small popping into place: a reaction, a bubble over a pinned face.
    static func popTransition(reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .scale(scale: 0.4).combined(with: .opacity)
    }

    /// The apps drawer springing out of the plus at its bottom leading corner.
    static func springOutTransition(reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .scale(scale: 0.3, anchor: .bottomLeading).combined(with: .opacity)
    }

    /// A picture arriving where its placeholder was: from a soft blur to sharp, the way a
    /// thumbnail sharpens. With Reduce Motion it cross-dissolves.
    static func blurUpTransition(reduced: Bool) -> AnyTransition {
        guard !reduced else {
            return .opacity
        }
        return .asymmetric(insertion: focus.combined(with: .opacity), removal: .opacity)
    }

    /// Unfolding down from its top edge: a voice note's transcript from under the note.
    static func unfoldTransition(reduced: Bool) -> AnyTransition {
        guard !reduced else {
            return .opacity
        }
        return .modifier(active: Unfolded(height: 0.2), identity: Unfolded(height: 1)).combined(with: .opacity)
    }

    /// Up from below and growing from `anchor`, as it fades in.
    private static func rise(from anchor: UnitPoint) -> AnyTransition {
        .scale(scale: 0.86, anchor: anchor)
            .combined(with: .offset(y: 14))
            .combined(with: .opacity)
    }

    /// From a soft blur to sharp.
    private static var focus: AnyTransition {
        .modifier(active: Blurred(radius: 12), identity: Blurred(radius: 0))
    }
}

/// Folded up towards its top edge, to `height` of its own height.
private struct Unfolded: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content.scaleEffect(x: 1, y: height, anchor: .top)
    }
}

/// Blurred by `radius`.
private struct Blurred: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

extension EnvironmentValues {
    /// Whether animations become fades: the app's own Reduce Motion choice, or the
    /// iPhone's while it follows the iPhone. `PhonePreferences` sets it at the root.
    @Entry var reducesMotion = false
}
