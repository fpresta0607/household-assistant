// The name a household member is drawn with before a gateway says who is who: in the
// onboarding, while a phone waits to be let in, and on the list of phones waiting. The
// real phones draw the household's own names; the screenshot tests draw the demo's
// made-up household (DemoRoom), so no picture of the app shows a real name or initial.

import SwiftUI

extension EnvironmentValues {
    /// What `member` is called on screen.
    @Entry var memberName: @Sendable (HouseholdMember) -> String = { $0.name }
}
