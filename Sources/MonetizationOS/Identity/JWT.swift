import CryptoKit
import Foundation

/// Reads compact JWS parts without verifying anything. Used for the identity key (the identity
/// claim) and for offer-token expiry; the server is the only verifier.
enum JWT {
    private static let base64URLCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")

    static func isBase64URL(_ part: Substring) -> Bool {
        !part.isEmpty && part.unicodeScalars.allSatisfy(base64URLCharacters.contains)
    }

    static func base64URLDecode(_ part: Substring) -> Data? {
        guard isBase64URL(part) else { return nil }
        var base64 = part.replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard base64.count % 4 != 1 else { return nil }
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    /// The payload object of a JWT, or nil when it does not decode to a JSON object.
    static func payload(of token: String) -> [String: JSONValue]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let data = base64URLDecode(parts[1]) else { return nil }
        return JSONValue.parse(data)?.objectValue
    }

    /// The claim as MOS reads it: a string as is, a number as JavaScript prints it. nil when it is
    /// missing, empty or another type.
    static func claim(_ key: String, of token: String) -> String? {
        switch payload(of: token)?[key] {
        case .string(let value): value.isEmpty ? nil : value
        case .number(let value): javaScriptString(value)
        default: nil
        }
    }

    /// `Number.prototype.toString()`: the shortest digits that round-trip, plain from 1e-7 up to 1e21 and
    /// exponential outside, so `123` and not `123.0`.
    static func javaScriptString(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        if value == 0 { return "0" }
        if value < 0 { return javaScriptString(-value).map { "-\($0)" } }
        // Swift's description has the same shortest digits; only the layout differs ("1.5e-07", "123.0").
        let text = value.description
        let parts = text.split(separator: "e")
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        var digits = mantissa.joined()
        var point = mantissa[0].count + (parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        while digits.hasPrefix("0") {
            digits.removeFirst()
            point -= 1
        }
        while digits.hasSuffix("0") { digits.removeLast() }
        let count = digits.count
        if count <= point, point <= 21 { return digits + String(repeating: "0", count: point - count) }
        if 0 < point, point <= 21 { return "\(digits.prefix(point)).\(digits.dropFirst(point))" }
        if -6 < point, point <= 0 { return "0." + String(repeating: "0", count: -point) + digits }
        let exponent = point - 1
        let sign = exponent < 0 ? "-" : "+"
        let head = count == 1 ? digits : "\(digits.prefix(1)).\(digits.dropFirst())"
        return "\(head)e\(sign)\(abs(exponent))"
    }
}

enum IdentityKey {
    static func anonymous(_ identifier: String) -> String { "anon:\(identifier)" }

    /// `jwt:` plus the SHA-256 of the identity claim (`claimKey`), or of the whole token when it has no
    /// readable one, so a refreshed token for the same user keeps the same key.
    static func jwt(_ token: String, claimKey: String = "sub") -> String {
        "jwt:\(sha256Hex(JWT.claim(claimKey, of: token) ?? token))"
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The part of a key that may be logged.
    static func prefix(_ key: String) -> String {
        String(key.prefix(while: { $0 != ":" }))
    }
}
