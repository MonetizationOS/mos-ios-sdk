import Foundation

/// A surface decision. Decoded leniently: unknown property types, missing optional fields and
/// open experience JSON never fail the decision. Only `status: "success"` and an `identity`
/// with a boolean `isAuthenticated` are required.
public struct Decision: Sendable, Equatable {
    public let eventID: String?
    public let identity: DecisionIdentity
    public let customer: Customer
    public let features: [String: Feature]
    /// `surfaceBehavior.properties`, or an empty object when absent.
    public let surfaceProperties: JSONValue
    public let surfaceBehavior: JSONValue
    public let componentBehaviors: [String: Component]
    public let componentsSkipped: Bool
    /// The whole response body as received. Served from the cache, its meters carry the device's
    /// count since the last network decision.
    public let raw: JSONValue

    public init?(json: JSONValue) {
        guard json["status"]?.stringValue == "success",
              let identity = json["identity"].flatMap(DecisionIdentity.init(json:))
        else { return nil }
        self.identity = identity
        eventID = json["eventId"]?.stringValue
        customer = Customer(json: json["customer"])
        var features: [String: Feature] = [:]
        for (slug, value) in json["features"]?.objectValue ?? [:] {
            if let feature = Feature(slug: slug, json: value) { features[slug] = feature }
        }
        self.features = features
        let surfaceBehavior = json["surfaceBehavior"].flatMap { $0.objectValue == nil ? nil : $0 } ?? .object([:])
        self.surfaceBehavior = surfaceBehavior
        surfaceProperties = surfaceBehavior["properties"].flatMap { $0.objectValue == nil ? nil : $0 } ?? .object([:])
        var components: [String: Component] = [:]
        for (slug, value) in json["componentBehaviors"]?.objectValue ?? [:] where value.objectValue != nil {
            components[slug] = Component(
                properties: value["properties"] ?? .object([:]),
                metadata: value["metadata"] ?? .object([:])
            )
        }
        componentBehaviors = components
        componentsSkipped = json["componentsSkipped"]?.boolValue ?? false
        raw = json
    }

    /// Every meterable property as `(feature, property, meter)`, sorted by feature then property.
    var meterables: [(String, String, Meterable)] {
        features.keys.sorted().flatMap { featureSlug in
            let properties = features[featureSlug]?.properties ?? [:]
            return properties.keys.sorted().compactMap { propertySlug -> (String, String, Meterable)? in
                guard case .meterable(let meter) = properties[propertySlug] else { return nil }
                return (featureSlug, propertySlug, meter)
            }
        }
    }
}

public struct DecisionIdentity: Sendable, Equatable {
    public let identifier: String?
    public let isAuthenticated: Bool
    public let authType: String?
    public let jwtClaims: JSONValue

    init?(json: JSONValue) {
        guard let isAuthenticated = json["isAuthenticated"]?.boolValue else { return nil }
        self.isAuthenticated = isAuthenticated
        identifier = json["identifier"]?.stringValue
        authType = json["authType"]?.stringValue
        jwtClaims = json["jwtClaims"] ?? .object([:])
    }
}

public struct Customer: Sendable, Equatable {
    public let isCustomer: Bool
    public let hasProducts: Bool
    public let customerIdentifiers: [String]

    init(json: JSONValue?) {
        isCustomer = json?["isCustomer"]?.boolValue ?? false
        hasProducts = json?["hasProducts"]?.boolValue ?? false
        customerIdentifiers = json?["customerIdentifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

public struct Component: Sendable, Equatable {
    public let properties: JSONValue
    public let metadata: JSONValue
}

public struct Feature: Sendable, Equatable {
    public let featureID: String
    public let featureSlug: String
    public let properties: [String: Property]

    init?(slug: String, json: JSONValue) {
        guard json.objectValue != nil else { return nil }
        featureID = json["featureId"]?.stringValue ?? ""
        featureSlug = json["featureSlug"]?.stringValue ?? slug
        var properties: [String: Property] = [:]
        for (key, value) in json["properties"]?.objectValue ?? [:] {
            properties[key] = Property(json: value)
        }
        self.properties = properties
    }
}

/// A feature property. A type this SDK does not know, or a known type with a malformed shape,
/// decodes as `unknown` so a server-side addition never fails the decision.
public enum Property: Sendable, Equatable {
    case meterable(Meterable)
    case number(Double?, isFallback: Bool)
    case string(String?, isFallback: Bool)
    case boolean(Bool?, isFallback: Bool)
    case unknown(type: String, JSONValue)

    init(json: JSONValue) {
        let type = json["type"]?.stringValue ?? ""
        let isFallback = json["isFallback"]?.boolValue ?? false
        let value = json["value"] ?? .null
        switch (type, value) {
        case ("meterable", _):
            self = Meterable(json: json).map(Property.meterable) ?? .unknown(type: type, json)
        case ("number", .null): self = .number(nil, isFallback: isFallback)
        case ("number", .number(let number)): self = .number(number, isFallback: isFallback)
        case ("string", .null): self = .string(nil, isFallback: isFallback)
        case ("string", .string(let string)): self = .string(string, isFallback: isFallback)
        case ("boolean", .null): self = .boolean(nil, isFallback: isFallback)
        case ("boolean", .bool(let bool)): self = .boolean(bool, isFallback: isFallback)
        default: self = .unknown(type: type, json)
        }
    }
}

/// A meterable property. Only `counterID`, `hasAccess` and `isFallback` are guaranteed.
public struct Meterable: Sendable, Equatable {
    public let counterID: String
    public let hasAccess: Bool
    public let isFallback: Bool
    public let consumedUnits: Double?
    public let remainingUnits: Double?
    public let totalUnits: Double?
    public let periodStart: String?
    public let uniqueResources: Bool?
    public let resourceIDUsed: Bool?
    public let consumedInRequest: Bool?
    public let consumedUnitsInRequest: Double?
    public let excessUnitsInRequest: Double?
    /// Set by the SDK, never the server: `offline.enforceMeters` turned access off because reads
    /// counted on this device since the last network decision used the meter up.
    public let lockedOffline: Bool

    init?(json: JSONValue) {
        guard let counterID = json["counterId"]?.stringValue, let hasAccess = json["hasAccess"]?.boolValue else { return nil }
        self.counterID = counterID
        self.hasAccess = hasAccess
        isFallback = json["isFallback"]?.boolValue ?? false
        consumedUnits = json["consumedUnits"]?.doubleValue
        remainingUnits = json["remainingUnits"]?.doubleValue
        totalUnits = json["totalUnits"]?.doubleValue
        periodStart = json["periodStart"]?.stringValue
        uniqueResources = json["uniqueResources"]?.boolValue
        resourceIDUsed = json["resourceIdUsed"]?.boolValue
        consumedInRequest = json["consumedInRequest"]?.boolValue
        consumedUnitsInRequest = json["consumedUnitsInRequest"]?.doubleValue
        excessUnitsInRequest = json["excessUnitsInRequest"]?.doubleValue
        lockedOffline = json["lockedOffline"]?.boolValue ?? false
    }
}
