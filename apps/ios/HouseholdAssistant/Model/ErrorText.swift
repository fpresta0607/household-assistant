// One sentence a person can read for any failure the app can meet.

import Foundation

enum ErrorText {
    static func describe(_ error: Error) -> String {
        if let shape = error as? GatewayErrorShape {
            return shape.message
        }
        if let signIn = error as? OAuthSignInFailure {
            return signIn.sentence
        }
        if let link = error as? GatewayConnectionError {
            switch link {
            case .notConnected:
                return "Not connected to your assistant."
            case .timedOut:
                return "Your assistant took too long to answer."
            case .unexpectedFrame:
                return "Your assistant sent something this app does not understand."
            }
        }
        return error.localizedDescription
    }
}
