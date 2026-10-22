// A setup code, as Corey or Denise sends it in Telegram after `/app`: the gateway's
// address and a single-use token that works for ten minutes. It is OpenClaw's own
// setup code, unpadded base64url of JSON, with the person and the assistant added.
//
// It arrives pasted on its own, inside the whole copied message, or as the link
// `steward://pair?code=<code>`. It carries nothing long-lived: once the phone has
// paired, the token is spent.

import Foundation

struct PairingCode: Equatable, Sendable {
    let url: URL
    let bootstrapToken: String
    /// Who the code is for, and their assistant's name, when the gateway said.
    let person: String?
    let assistant: String?

    private struct Payload: Decodable {
        let url: String?
        let bootstrapToken: String?
        let expiresAtMs: Double?
        let person: String?
        let assistant: String?
    }

    init?(text: String, now: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = URLComponents(string: trimmed),
           link.scheme?.lowercased() == "steward",
           link.host?.lowercased() == "pair" {
            guard
                let code = link.queryItems?.first(where: { $0.name == "code" })?.value,
                let parsed = PairingCode(code: code, now: now)
            else {
                return nil
            }
            self = parsed
            return
        }
        // A copied message holds the code as one long word among short ones.
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for word in words.sorted(by: { $0.count > $1.count }) {
            if let code = PairingCode(code: word, now: now) {
                self = code
                return
            }
        }
        return nil
    }

    private init?(code: String, now: Date) {
        guard
            code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
            let data = Base64URL.decode(code),
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            let address = payload.url,
            let url = URL(string: address),
            let scheme = url.scheme?.lowercased(),
            scheme == "ws" || scheme == "wss",
            url.host?.isEmpty == false,
            let token = payload.bootstrapToken,
            !token.isEmpty
        else {
            return nil
        }
        if let expiresAtMs = payload.expiresAtMs, Date(timeIntervalSince1970: expiresAtMs / 1000) <= now {
            return nil
        }
        self.url = url
        self.bootstrapToken = token
        self.person = payload.person
        self.assistant = payload.assistant
    }
}
