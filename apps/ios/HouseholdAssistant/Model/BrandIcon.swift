// What the gateway's `icon` names: a company's or a household app's own logo in the
// asset catalog (`anthropic`, `pocketpiggies`, `zai`), or an SF Symbol after `symbol:`.

import Foundation

enum BrandIcon: Equatable, Sendable {
    case logo(String)
    case symbol(String)

    static let symbolPrefix = "symbol:"

    init(name: String) {
        if name.hasPrefix(Self.symbolPrefix) {
            self = .symbol(String(name.dropFirst(Self.symbolPrefix.count)))
        } else {
            self = .logo(name)
        }
    }
}
