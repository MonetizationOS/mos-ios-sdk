import Foundation

/// A resolved experience, as a workflow puts it in `surfaceBehavior.properties` or a
/// component's `properties`. The SDK does not know the key; the host names it.
public enum Experience: Sendable, Equatable {
    /// An `app` experience: its JSON without `mos-offer-slots`, and the presentation schema id
    /// when it arrived as a web-content `element`.
    case native(content: [String: JSONValue], schema: String?, offers: [OfferSlot])
    /// An `html` experience, ready for `MOSWebPaywallView`. Offers are already in the markup.
    case web(html: String)

    /// The native experience's offer slots; a web experience has its offers in the markup.
    public var offers: [OfferSlot] {
        switch self {
        case .native(_, _, let offers): offers
        case .web: []
        }
    }

    /// nil when the value is not a resolved experience, including `{}` (nothing bound).
    public static func decode(_ json: JSONValue) -> Experience? {
        switch json {
        case .object(let object):
            return object.isEmpty ? nil : native(object, schema: nil)
        case .array(let items):
            return decodeWebContent(items)
        default:
            return nil
        }
    }

    /// Decodes a native experience's content into the host's own type. Throws for `web`.
    public func decode<T: Decodable>(_ type: T.Type = T.self, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard case .native(let content, _, _) = self else {
            throw DecodingError.typeMismatch(T.self, .init(codingPath: [], debugDescription: "A web experience has no native content"))
        }
        return try decoder.decode(T.self, from: JSONValue.object(content).encoded())
    }

    private static func native(_ object: [String: JSONValue], schema: String?) -> Experience {
        var content = object
        let slots = content.removeValue(forKey: offerSlotsKey)
        return .native(content: content, schema: schema, offers: slots.map(offerSlots) ?? [])
    }

    /// Either all `html`/`text` items, or exactly one `element`. Anything else is not ours.
    private static func decodeWebContent(_ items: [JSONValue]) -> Experience? {
        if items.count == 1, items[0]["type"]?.stringValue == "element" {
            guard let schema = items[0]["schema"]?.stringValue, let props = items[0]["props"]?.objectValue else { return nil }
            return native(props, schema: schema)
        }
        guard !items.isEmpty else { return nil }
        var html = ""
        for item in items {
            guard let content = item["content"]?.stringValue else { return nil }
            switch item["type"]?.stringValue {
            case "html": html += content
            case "text": html += escapeHTML(content)
            default: return nil
            }
        }
        return .web(html: html)
    }

    static let offerSlotsKey = "mos-offer-slots"

    static func escapeHTML(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}

/// One entry of `mos-offer-slots`. `offer` is nil when the workflow bound no offer, or the
/// offer lacked a string `id` or `token`.
public struct OfferSlot: Sendable, Equatable {
    public let type: String
    public let offer: Offer?

    public init(type: String, offer: Offer?) {
        self.type = type
        self.offer = offer
    }
}

public struct Offer: Sendable, Equatable {
    public let id: String
    public let presentation: [String: JSONValue]
    public let redemptionSchema: String?
    /// Pass to `MOS.redeem(offerToken:)`.
    public let token: String
    /// The token payload's `expirationMsUtc`, read without verification.
    public let expiresAt: Date?
    /// `presentation.storeProductId`, the one presentation key the SDK reads, so native and web
    /// paywalls can price the offer.
    public let storeProductID: String?

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let token = json["token"]?.stringValue else { return nil }
        self.id = id
        self.token = token
        presentation = json["presentation"]?.objectValue ?? [:]
        redemptionSchema = json["redemptionSchema"]?.stringValue
        expiresAt = OfferTokens.decode(token)?.expirationMsUtc.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        storeProductID = presentation["storeProductId"]?.stringValue
    }
}

/// Decodes a `mos-offer-slots` array. A slot that is not an object with a string `type` is
/// skipped; anything that is not an array gives no slots.
func offerSlots(_ json: JSONValue) -> [OfferSlot] {
    (json.arrayValue ?? []).compactMap { slot in
        guard let type = slot["type"]?.stringValue else { return nil }
        return OfferSlot(type: type, offer: slot["offer"].flatMap(Offer.init(json:)))
    }
}

extension Decision {
    /// The resolved experience at `surfaceBehavior.properties[key]`, or at
    /// `componentBehaviors[component].properties[key]` when `component` is given.
    public func experience(_ key: String, component: String? = nil) -> Experience? {
        let properties: JSONValue? = if let component { componentBehaviors[component]?.properties } else { surfaceProperties }
        return properties?[key].flatMap(Experience.decode)
    }
}
