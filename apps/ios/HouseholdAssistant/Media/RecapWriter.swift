// The line under a month's recap, written by Apple's on-device model from the month's facts
// alone (RecapLine.prompt): no photo and nothing else goes to it, and it never leaves the
// phone. Where Apple Intelligence is off or not on this iPhone, and whenever the model has
// nothing usable to say, the plain line stands in, which is the line the recap is designed
// to fall back to rather than a hidden failure.

import FoundationModels

enum RecapWriter {
    static func line(for recap: MonthlyRecap) async -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            return RecapLine.plain(for: recap)
        }
        do {
            let answer = try await LanguageModelSession().respond(to: RecapLine.prompt(for: recap))
            return RecapLine.cleaned(answer.content) ?? RecapLine.plain(for: recap)
        } catch {
            return RecapLine.plain(for: recap)
        }
    }
}
