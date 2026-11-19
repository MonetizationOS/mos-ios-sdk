import Foundation
import MonetizationOS

/// Answers every SDK request from the bundled `fixtures/` folder, so the app runs with no key and
/// no backend while still going through the SDK's real code path. The rules (routes, templates,
/// state) are in fixtures/README.md; the Android SDK's Showcase app implements the same ones.
actor FixtureTransport: HTTPTransport {
    private let directory: URL
    private let routes: [String: Any]
    private let offers: [String: [String: Any]]
    /// `<identity key>|<counterId>` to the resource ids that consumed the meter.
    private var meters: [String: Set<String>] = [:]
    /// `<identity key>|<offer id>` for offers that can be claimed once.
    private var claimed: Set<String> = []

    init(bundle: Bundle = .main) {
        guard let directory = bundle.url(forResource: "fixtures", withExtension: nil) else {
            fatalError("The fixtures folder is missing from the app bundle")
        }
        self.directory = directory
        routes = Self.readJSON(directory.appending(path: "routes.json")) as? [String: Any] ?? [:]
        let list = Self.readJSON(directory.appending(path: "offers.json")) as? [[String: Any]] ?? []
        offers = Dictionary(list.compactMap { offer in (offer["id"] as? String).map { ($0, offer) } }) { first, _ in first }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await Task.sleep(for: .milliseconds(150))
        let path = request.url.path(percentEncoded: false)
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch (request.method, path) {
        case ("POST", "/api/v1/surface-decisions"): return decision(body)
        case ("POST", "/api/v1/offer-redemptions"): return redemption(body)
        case ("POST", "/api/v1/counter-updates"): return counterUpdate(body)
        default: break
        }
        // /api/v1/envs/{env}[/namespaces/{namespace}]/endpoints/{path}
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 5, parts[1] == "api", parts[2] == "v1", parts[3] == "envs" {
            let rest = Array(parts[5...])
            if rest.count > 3, rest[0] == "namespaces", rest[2] == "endpoints" {
                return endpoint(path: rest[3...].joined(separator: "/"), request: request)
            }
            if rest.count > 1, rest[0] == "endpoints" {
                return endpoint(path: rest[1...].joined(separator: "/"), request: request)
            }
        }
        return envelope(routes["notFound"] as? String ?? "", ["path": path])
    }

    // MARK: Routes

    private func decision(_ body: [String: Any]) -> HTTPResponse {
        let caller = Caller(identity: body["identity"] as? [String: Any] ?? [:])
        let surface = body["surfaceSlug"] as? String ?? ""
        let resourceId = (body["resource"] as? [String: Any])?["id"] as? String ?? ""
        let routeList = routes["decisions"] as? [[String: Any]] ?? []
        guard let route = routeList.first(where: { route in
            guard route["surface"] as? String == surface, let pattern = route["resource"] as? String else { return false }
            return pattern.hasSuffix("*") ? resourceId.hasPrefix(String(pattern.dropLast())) : pattern == resourceId
        }) else {
            return envelope(routes["notFound"] as? String ?? "", ["path": "\(surface) \(resourceId)"])
        }
        let file = (caller.isAuthenticated ? route["authenticatedFile"] as? String : nil) ?? route["file"] as? String ?? ""
        guard var decision = load(file, [:]) as? [String: Any] else { return Self.json(["status": "error"], status: 500) }
        decision["identity"] = caller.decisionIdentity
        if var features = decision["features"] as? [String: Any] {
            for (slug, value) in features {
                guard var feature = value as? [String: Any], var properties = feature["properties"] as? [String: Any] else { continue }
                for (key, property) in properties {
                    guard let meter = property as? [String: Any], meter["type"] as? String == "meterable" else { continue }
                    properties[key] = consume(meter, caller: caller, resourceId: resourceId)
                }
                feature["properties"] = properties
                features[slug] = feature
            }
            decision["features"] = features
        }
        return Self.json(decision)
    }

    /// A unique-resource meter: a new resource id consumes one unit while any remain; a used one is free.
    private func consume(_ template: [String: Any], caller: Caller, resourceId: String) -> [String: Any] {
        var meter = template
        let counterId = meter["counterId"] as? String ?? ""
        let total = meter["totalUnits"] as? Int ?? 0
        let key = "\(caller.key)|\(counterId)"
        var used = meters[key, default: []]
        let wasUsed = used.contains(resourceId)
        let consumed = !wasUsed && used.count < total
        if consumed { used.insert(resourceId) }
        meters[key] = used
        meter["hasAccess"] = wasUsed || consumed
        meter["isFallback"] = false
        meter["consumedUnits"] = used.count
        meter["remainingUnits"] = max(total - used.count, 0)
        meter["resourceIdUsed"] = wasUsed
        meter["consumedInRequest"] = consumed
        meter["consumedUnitsInRequest"] = consumed ? 1 : 0
        meter["excessUnitsInRequest"] = wasUsed || consumed ? 0 : 1
        return meter
    }

    private func redemption(_ body: [String: Any]) -> HTTPResponse {
        let caller = Caller(identity: body["identity"] as? [String: Any] ?? [:])
        guard let token = body["offerToken"] as? String,
              let offerId = Self.payload(ofToken: token)?["id"] as? String,
              let offer = offers[offerId],
              var file = offer["fixtureRedemption"] as? String
        else {
            return Self.json(["status": "error", "statusCode": 400, "message": "Invalid offer token"], status: 400)
        }
        if let repeatFile = offer["fixtureRepeatRedemption"] as? String {
            let claim = "\(caller.key)|\(offerId)"
            if claimed.contains(claim) { file = repeatFile } else { claimed.insert(claim) }
        }
        // Stands in for the offer's redemption values in MOS, which the redemption method's workflow reads.
        let values = (offer["fixtureRedemptionValues"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        return Self.json(load(file, values) ?? [:])
    }

    private func counterUpdate(_ body: [String: Any]) -> HTTPResponse {
        let caller = Caller(identity: body["identity"] as? [String: Any] ?? [:])
        if let counterId = body["counterId"] as? String, let resourceId = body["resourceId"] as? String {
            meters["\(caller.key)|\(counterId)", default: []].insert(resourceId)
        }
        return Self.json(load(routes["counterUpdate"] as? String ?? "", [:]) ?? [:])
    }

    private func endpoint(path: String, request: HTTPRequest) -> HTTPResponse {
        let routeList = routes["endpoints"] as? [[String: Any]] ?? []
        guard let route = routeList.first(where: { $0["method"] as? String == request.method && $0["path"] as? String == path }),
              let file = route["file"] as? String
        else {
            return envelope(routes["endpointNotFound"] as? String ?? "", ["path": path])
        }
        let requestBody = request.body.isEmpty ? "null" : String(decoding: request.body, as: UTF8.self)
        return envelope(file, ["requestBody": requestBody])
    }

    // MARK: Files

    /// A `{ status, headers, body }` file as an HTTP response.
    private func envelope(_ file: String, _ values: [String: String]) -> HTTPResponse {
        let envelope = load(file, values) as? [String: Any] ?? [:]
        var response = Self.json(envelope["body"] ?? NSNull(), status: envelope["status"] as? Int ?? 200)
        let headers = envelope["headers"] as? [String: String] ?? [:]
        response = HTTPResponse(status: response.status, headers: response.headers.merging(headers) { _, file in file }, body: response.body)
        return response
    }

    /// Reads a fixture, fills its placeholders, then expands offer slots and html content files.
    private func load(_ file: String, _ values: [String: String]) -> Any? {
        guard let text = try? String(contentsOf: directory.appending(path: file), encoding: .utf8) else { return nil }
        guard let data = fill(text, values).data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return expand(json)
    }

    private func fill(_ text: String, _ values: [String: String]) -> String {
        var text = text
        // A whole-value placeholder becomes raw JSON, so the quotes go with it.
        if let requestBody = values["requestBody"] { text = text.replacingOccurrences(of: "\"{{requestBody}}\"", with: requestBody) }
        text = text.replacingOccurrences(of: "{{eventId}}", with: UUID().uuidString.lowercased())
        for (name, value) in values where name != "requestBody" {
            text = text.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        while let range = text.range(of: #"\{\{token:[^}]+\}\}"#, options: .regularExpression) {
            let offerId = String(text[range].dropFirst("{{token:".count).dropLast(2))
            text.replaceSubrange(range, with: token(offerId))
        }
        return text
    }

    private func expand(_ value: Any) -> Any {
        if var object = value as? [String: Any] {
            for (key, child) in object {
                if key == "mos-offer-slots", let ids = child as? [Any] {
                    object[key] = ids.map { item in (item as? String).map(slot) ?? item }
                } else {
                    object[key] = expand(child)
                }
            }
            if object["type"] as? String == "html", let file = object.removeValue(forKey: "contentFile") as? String {
                let html = (try? String(contentsOf: directory.appending(path: file), encoding: .utf8)) ?? ""
                object["content"] = fill(html, [:])
            }
            return object
        }
        if let array = value as? [Any] { return array.map(expand) }
        return value
    }

    private func slot(_ offerId: String) -> [String: Any] {
        guard let offer = offers[offerId] else { return ["type": "single"] }
        return ["type": "single", "offer": [
            "id": offerId,
            "redemptionSchema": offer["redemptionSchema"] ?? NSNull(),
            "presentation": offer["presentation"] ?? [:],
            "token": token(offerId),
        ] as [String: Any]]
    }

    /// Shaped like the server's offer token; the SDK reads the payload, never the signature.
    private func token(_ offerId: String) -> String {
        let offer = offers[offerId] ?? [:]
        return Self.fakeJWT([
            "id": offerId,
            "presentation": offer["presentation"] ?? [:],
            "redemptionSchema": offer["redemptionSchema"] ?? NSNull(),
            "expirationMsUtc": Int((Date().timeIntervalSince1970 + 3600) * 1000),
        ])
    }

    // MARK: Helpers

    /// The caller of a request: `jwt:<sub>` or `anon:<id>`, minting an anonymous id when asked.
    private struct Caller {
        let key: String
        let identifier: String
        let isAuthenticated: Bool
        let claims: [String: Any]

        init(identity: [String: Any]) {
            if let token = identity["userJwt"] as? String {
                self.init(jwt: token)
            } else {
                self.init(anonymous: identity["anonymousIdentifier"] as? String)
            }
        }

        /// Fixture mode accepts any token; the subject comes from its payload when it has one.
        private init(jwt token: String) {
            let claims = FixtureTransport.payload(ofToken: token) ?? [:]
            let subject = claims["sub"] as? String ?? "user"
            self.init(key: "jwt:\(subject)", identifier: subject, isAuthenticated: true, claims: claims)
        }

        private init(anonymous identifier: String?) {
            let identifier = identifier ?? "mos-anon-v1-fixture-\(UUID().uuidString.lowercased())"
            self.init(key: "anon:\(identifier)", identifier: identifier, isAuthenticated: false, claims: [:])
        }

        private init(key: String, identifier: String, isAuthenticated: Bool, claims: [String: Any]) {
            self.key = key
            self.identifier = identifier
            self.isAuthenticated = isAuthenticated
            self.claims = claims
        }

        var decisionIdentity: [String: Any] {
            ["identifier": identifier, "isAuthenticated": isAuthenticated, "authType": isAuthenticated ? "jwt" : "anonymous", "jwtClaims": claims]
        }
    }

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    private static func readJSON(_ url: URL) -> Any? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    static func fakeJWT(_ payload: [String: Any]) -> String {
        func part(_ object: Any) -> String {
            base64url((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
        }
        let signature = base64url(Data((0..<64).map { _ in UInt8.random(in: 0...255) }))
        return "\(part(["alg": "ES256", "typ": "JWT"])).\(part(payload)).\(signature)"
    }

    static func payload(ofToken token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
