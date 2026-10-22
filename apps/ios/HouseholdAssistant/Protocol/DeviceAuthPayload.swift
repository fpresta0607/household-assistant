// The string a device signs to prove it holds its key: payload version 3.
//
// Mirrors `buildDeviceAuthPayloadV3` in the gateway
// (`packages/gateway-client/src/device-auth.ts`): eleven fields joined by `|`,
// scopes joined by `,`, and the two metadata fields trimmed and ASCII-lowercased.

import Foundation

enum DeviceAuthPayload {
    static func v3(
        deviceId: String,
        client: ClientInfo,
        role: String,
        scopes: [String],
        signedAtMs: Int,
        token: String?,
        nonce: String
    ) -> String {
        [
            "v3",
            deviceId,
            client.id,
            client.mode,
            role,
            scopes.joined(separator: ","),
            String(signedAtMs),
            token ?? "",
            nonce,
            normalizeMetadata(client.platform),
            normalizeMetadata(client.deviceFamily),
        ].joined(separator: "|")
    }

    /// Only A to Z are folded, as in the gateway; `lowercased()` would also
    /// fold non-ASCII letters and produce a payload the gateway does not build.
    static func normalizeMetadata(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var folded = String.UnicodeScalarView()
        for scalar in trimmed.unicodeScalars {
            if scalar.value >= 65, scalar.value <= 90, let lower = Unicode.Scalar(scalar.value + 32) {
                folded.append(lower)
            } else {
                folded.append(scalar)
            }
        }
        return String(folded)
    }
}
