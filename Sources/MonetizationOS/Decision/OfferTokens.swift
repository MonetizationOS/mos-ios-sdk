import Foundation

/// The readable payload of a signed offer token.
struct OfferTokenPayload: Sendable, Equatable {
    let expirationMsUtc: Int64?
}

enum OfferTokens {
    /// A string is an offer token when it has three base64url parts and the middle one decodes
    /// to a JSON object. Anything else is not a token, never an error.
    static func decode(_ token: String) -> OfferTokenPayload? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy(JWT.isBase64URL),
              let data = JWT.base64URLDecode(parts[1]),
              let payload = JSONValue.parse(data)?.objectValue
        else { return nil }
        let expiration = payload["expirationMsUtc"]?.doubleValue.map(saturatingInt64)
        return OfferTokenPayload(expirationMsUtc: expiration)
    }

    /// Truncates, saturates at the Int64 bounds, NaN is 0, as the Android SDK does.
    private static func saturatingInt64(_ value: Double) -> Int64 {
        if value.isNaN { return 0 }
        if value >= 0x1p63 { return .max }
        if value <= -0x1p63 { return .min }
        return Int64(value)
    }

    /// Every token under `surfaceBehavior` and each `componentBehaviors.*` of a raw decision: the
    /// string under each `token` key, and the tokens a web paywall would redeem from each string.
    static func discover(in decision: JSONValue) -> [OfferTokenPayload] {
        var found: [OfferTokenPayload] = []
        if let surface = decision["surfaceBehavior"] { walk(surface, into: &found) }
        for component in (decision["componentBehaviors"]?.objectValue ?? [:]).values {
            walk(component, into: &found)
        }
        return found
    }

    /// The earliest token expiry in a raw decision, ignoring tokens without one.
    static func earliestExpiry(in decision: JSONValue) -> Int64? {
        discover(in: decision).compactMap(\.expirationMsUtc).min()
    }

    private static func walk(_ value: JSONValue, into found: inout [OfferTokenPayload]) {
        switch value {
        case .object(let object):
            if let token = object["token"]?.stringValue, let payload = decode(token) { found.append(payload) }
            for child in object.values { walk(child, into: &found) }
        case .array(let array):
            for child in array { walk(child, into: &found) }
        case .string(let text):
            found += markupTokens(in: text).compactMap(decode)
        default:
            break
        }
    }

    private static let redeemURL = Array("mos://redeem".unicodeScalars)
    private static let redeemAttribute = Array("data-mos-redeem".unicodeScalars)

    /// The tokens a web paywall would redeem from `text`, in order: the first `token` query
    /// parameter of each `mos://redeem` URL, percent-decoded, and each `data-mos-redeem` attribute
    /// value. Character references are decoded first, as the HTML parser does. The Android SDK
    /// applies the same rules (fixtures/offer-tokens-markup.json).
    static func markupTokens(in text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var found: [String] = []
        var i = 0
        while i < scalars.count {
            if startsWith(scalars, redeemURL, at: i) {
                let end = valueEnd(scalars, from: i)
                if let token = redeemURLToken(decodeCharacterReferences(scalars[i..<end])) { found.append(token) }
                i = end
            } else if startsWith(scalars, redeemAttribute, at: i), case let (value, end)? = attributeValue(scalars, from: i + redeemAttribute.count) {
                let token = String(String.UnicodeScalarView(decodeCharacterReferences(value)))
                if !token.isEmpty { found.append(token) }
                i = end
            } else {
                i += 1
            }
        }
        return found
    }

    /// The web paywall's rule for a `mos://` navigation: the host is `redeem`, and the token is the
    /// first `token` query parameter, percent-decoded (`+` stays `+`), not empty.
    private static func redeemURLToken(_ decoded: [Unicode.Scalar]) -> String? {
        let url = decoded.prefix { !isDelimiter($0) }
        let afterHost = url.dropFirst(redeemURL.count)
        if let next = afterHost.first, !"/?#".unicodeScalars.contains(next) { return nil }
        let beforeFragment = afterHost.prefix { $0 != "#" }
        guard let mark = beforeFragment.firstIndex(of: "?") else { return nil }
        let parameters = beforeFragment[(mark + 1)...].split(separator: "&", omittingEmptySubsequences: false)
        guard let parameter = parameters.first(where: { $0.prefix { $0 != "=" }.elementsEqual("token".unicodeScalars) }) else { return nil }
        let value = parameter.drop { $0 != "=" }.dropFirst()
        guard let token = String(String.UnicodeScalarView(value)).removingPercentEncoding, !token.isEmpty else { return nil }
        return token
    }

    /// The value after `=` (whitespace allowed around it): quoted, or unquoted up to a delimiter.
    private static func attributeValue(_ scalars: [Unicode.Scalar], from start: Int) -> (ArraySlice<Unicode.Scalar>, Int)? {
        var i = skipWhitespace(scalars, from: start)
        guard i < scalars.count, scalars[i] == "=" else { return nil }
        i = skipWhitespace(scalars, from: i + 1)
        guard i < scalars.count else { return nil }
        let quote = scalars[i]
        if quote == "\"" || quote == "'" {
            guard let close = scalars[(i + 1)...].firstIndex(of: quote) else { return nil }
            return (scalars[(i + 1)..<close], close + 1)
        }
        let end = valueEnd(scalars, from: i)
        return end > i ? (scalars[i..<end], end) : nil
    }

    /// A URL or an unquoted value ends at HTML whitespace, a quote, `<`, `>`, a backtick or `\`.
    private static func isDelimiter(_ scalar: Unicode.Scalar) -> Bool {
        isWhitespace(scalar) || "\"'<>`\\".unicodeScalars.contains(scalar)
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        "\t\n\u{0C}\r ".unicodeScalars.contains(scalar)
    }

    private static func valueEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        scalars[start...].firstIndex(where: isDelimiter) ?? scalars.count
    }

    private static func skipWhitespace(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        scalars[start...].firstIndex { !isWhitespace($0) } ?? scalars.count
    }

    /// ASCII case-insensitive, as URL schemes and HTML attribute names are.
    private static func startsWith(_ scalars: [Unicode.Scalar], _ marker: [Unicode.Scalar], at i: Int) -> Bool {
        guard scalars.count - i >= marker.count else { return false }
        return marker.indices.allSatisfy { k in
            let scalar = scalars[i + k]
            return (("A"..."Z").contains(scalar) ? Unicode.Scalar(UInt8(scalar.value) + 32) : scalar) == marker[k]
        }
    }

    /// Decodes `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;` and numeric references; anything else
    /// stays as written.
    private static func decodeCharacterReferences(_ scalars: ArraySlice<Unicode.Scalar>) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var i = scalars.startIndex
        while i < scalars.endIndex {
            if scalars[i] == "&" {
                let name = scalars[(i + 1)...].prefix { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "#" }
                if name.endIndex < scalars.endIndex, scalars[name.endIndex] == ";", let decoded = characterReference(String(String.UnicodeScalarView(name))) {
                    out.append(decoded)
                    i = name.endIndex + 1
                    continue
                }
            }
            out.append(scalars[i])
            i += 1
        }
        return out
    }

    private static func characterReference(_ name: String) -> Unicode.Scalar? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default: break
        }
        guard name.hasPrefix("#") else { return nil }
        let hex = name.hasPrefix("#x") || name.hasPrefix("#X")
        guard let value = Int(name.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), value > 0 else { return nil }
        // nil for a surrogate or beyond U+10FFFF.
        return Unicode.Scalar(UInt32(clamping: value))
    }
}
