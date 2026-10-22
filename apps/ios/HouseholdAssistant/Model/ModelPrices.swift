// A model's price as Settings writes it under its name, or just the company until
// OpenRouter's list has been read. A text model's is "Z.ai, $0.10 in, $0.40 out per
// million" or "DeepSeek, free", shared by the model page and the pickers of its second
// and third model. An image or video model's is in the unit OpenRouter bills it by:
// "OpenAI, $30 per million image tokens", "Google, $0.10 per second at 720p", or
// "Acme, no price on OpenRouter" when it lists none.

import Foundation

enum ModelPrices {
    static func line(_ listed: OpenRouterModel?, company: String, perMillion: Bool) -> String {
        guard let listed else {
            return company
        }
        if listed.inputPerMillion == 0 && listed.outputPerMillion == 0 {
            return "\(company), free"
        }
        let prices = "\(company), \(Dollars.price(listed.inputPerMillion)) in, \(Dollars.price(listed.outputPerMillion)) out"
        return perMillion ? prices + " per million" : prices
    }

    static func line(_ listed: MediaModel?, company: String) -> String {
        guard let listed else {
            return company
        }
        guard let price = listed.price else {
            return "\(company), no price on OpenRouter"
        }
        if price.dollars == 0 {
            return "\(company), free"
        }
        return "\(company), \(Dollars.price(price.dollars)) per \(price.per)"
    }
}
