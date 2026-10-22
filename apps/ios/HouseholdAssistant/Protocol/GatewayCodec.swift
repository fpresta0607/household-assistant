// Text frames in, text frames out. The gateway speaks JSON text frames only.

import Foundation

enum GatewayCodec {
    static func encode(_ request: GatewayRequest) throws -> String {
        let data = try JSONEncoder().encode(request)
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a frame in one pass. An answer to a request in `answerTypes` is read straight
    /// into the model it wants; every other payload is kept as JSON.
    static func decode(_ text: String, answerTypes: GatewayAnswerTypes? = nil) throws -> GatewayFrame {
        let decoder = JSONDecoder()
        if let answerTypes {
            decoder.userInfo[GatewayAnswerTypes.userInfoKey] = answerTypes
        }
        return try decoder.decode(GatewayFrame.self, from: Data(text.utf8))
    }
}
