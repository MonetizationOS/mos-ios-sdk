import Foundation
import Testing
@testable import MonetizationOS

@Suite("Requests")
struct RequestTests {
    struct FailureCase: Sendable, CustomTestStringConvertible {
        let reason: Failure.Reason
        let response: FakeTransport.Handler
        let status: Int?
        var testDescription: String { reason.rawValue }
    }

    static let failureCases: [FailureCase] = [
        FailureCase(reason: .requestFailed, response: networkDown, status: nil),
        FailureCase(reason: .timeout, response: { _ in throw URLError(.timedOut) }, status: nil),
        FailureCase(reason: .invalidJSON, response: { _ in .fixture("invalid-json.txt") }, status: 200),
        FailureCase(reason: .apiError, response: { _ in .fixture("error-400.json", status: 400) }, status: 400),
        FailureCase(reason: .httpError, response: { _ in .fixture("invalid-json.txt", status: 502) }, status: 502),
        FailureCase(reason: .invalidResponse, response: { _ in .json(["status": "success"]) }, status: 200),
        FailureCase(reason: .rateLimited, response: { _ in .fixture("error-429.json", status: 429) }, status: 429),
        FailureCase(reason: .unauthorized, response: { _ in .fixture("error-401.json", status: 401) }, status: 401),
    ]

    @Test("no retry: one transport call for every failure reason, and the cache still serves", arguments: failureCases)
    func noRetry(_ failureCase: FailureCase) async {
        let harness = Harness(
            anonymousIdentifier: "mos-anon-v1-abc",
            cached: [Decisions.entry(resourceId: "article/1")],
            handler: failureCase.response
        )
        let result = await harness.decide("article/1")
        #expect(harness.transport.count == 1)
        #expect(result.failure?.reason == failureCase.reason)
        #expect(result.failure?.status == failureCase.status)
        #expect(result.source == .cache(ageMs: 0))
        #expect(harness.logs.events("decision:error").first?.context["reason"] == .string(failureCase.reason.rawValue))
    }

    @Test("headers: Authorization, Content-Type, User-Agent and X-MOS-Mobile-Version, exactly")
    func headers() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", queued: [Decisions.queued()], handler: route())
        await harness.decide("article/1")
        _ = await harness.mos.redeem(offerToken: Tokens.offer(expirationMsUtc: nil))
        let userAgent = await harness.mos.userAgent

        let paths = harness.transport.requests.map(\.url.path)
        #expect(paths == ["/api/v1/surface-decisions", "/api/v1/counter-updates", "/api/v1/offer-redemptions"])
        for request in harness.transport.requests {
            #expect(request.headers == [
                "Authorization": "Bearer \(TestKeys.publicKey)",
                "Content-Type": "application/json",
                "User-Agent": userAgent,
                "X-MOS-Mobile-Version": "ios/\(MOSVersion)",
            ])
        }
    }

    @Test("a JWT carries createAnonymousIdentifierFallback on surface-decisions only")
    func jwtFallbackFlagOnDecisionsOnly() async {
        let jwt = Tokens.jwt(sub: "user_42")
        let harness = Harness(
            jwtProvider: { jwt },
            queued: [Decisions.queued(identityKey: IdentityKey.jwt(jwt))],
            handler: route(decision: { request in
                request.url.path == "/api/v1/offer-redemptions" ? .fixture("redemption-none.json") : .json(Decisions.make(identifier: "user_42", isAuthenticated: true))
            })
        )
        await harness.decide("article/1")
        _ = await harness.mos.redeem(offerToken: Tokens.offer(expirationMsUtc: nil))

        let identity = { (path: String) in harness.transport.requests(to: path).first?.json["identity"] }
        #expect(identity("/api/v1/surface-decisions") == ["userJwt": .string(jwt), "createAnonymousIdentifierFallback": true])
        #expect(identity("/api/v1/counter-updates") == ["userJwt": .string(jwt)])
        #expect(identity("/api/v1/counter-updates")?["createAnonymousIdentifierFallback"] == nil)
        #expect(identity("/api/v1/offer-redemptions") == ["userJwt": .string(jwt)])
        #expect(identity("/api/v1/offer-redemptions")?["createAnonymousIdentifierFallback"] == nil)
    }

    @Test("the User-Agent names the app, platform, device and SDK, and nothing bot-like")
    func userAgentShape() async throws {
        let userAgent = await Harness().mos.userAgent
        let pattern = try Regex(#"^Herald/2\.1 \((iOS|macOS|tvOS|visionOS|watchOS) [0-9]+\.[0-9]+(\.[0-9]+)?; [^;()]+\) MOS-iOS/"# + MOSVersion.replacingOccurrences(of: ".", with: #"\."#) + "$")
        #expect(userAgent.wholeMatch(of: pattern) != nil, "\(userAgent)")
        for word in ["bot", "crawler", "spider", "curl", "okhttp", "python", "CFNetwork", "Darwin"] {
            #expect(!userAgent.lowercased().contains(word.lowercased()))
        }
    }

    /// The Android SDK's cases too: both SDKs give the same User-Agent up to the SDK suffix.
    static let userAgentCases: [(app: (String, String), device: (String, String, String), expected: String)] = [
        (("Herald", "2.1"), ("iOS", "18.2", "iPhone17,1"), "Herald/2.1 (iOS 18.2; iPhone17,1)"),
        (("Future Herald", "2.3 (45)"), ("Android", "16", "Pixel 9 Pro"), "Future-Herald/2.3-45 (Android 16; Pixel 9 Pro)"),
        (("Zeit für Brot – News", "3.0 β"), ("iOS", "26.1", "iPhone18,1"), "Zeit-f-r-Brot-News/3.0 (iOS 26.1; iPhone18,1)"),
        (("新聞アプリ", "1.0"), ("Android", "16", "Pixel 9"), "app/1.0 (Android 16; Pixel 9)"),
        (("-Herald-", "1.0--beta"), ("iOS", " 18.2 ", "Pixel (9); Pro\\ü"), "Herald/1.0--beta (iOS 18.2; Pixel 9 Pro)"),
        (("Herald", "2.1"), ("ü", "16", ""), "Herald/2.1 (16; )"),
        // A blank name or version is not an error: each becomes `app`.
        (("", ""), ("iOS", "18.2", "iPhone17,1"), "app/app (iOS 18.2; iPhone17,1)"),
        ((" ", "\t"), ("Android", "16", "Pixel 9"), "app/app (Android 16; Pixel 9)"),
        (("Herald", " "), ("iOS", "18.2", "iPhone17,1"), "Herald/app (iOS 18.2; iPhone17,1)"),
    ]

    @Test("the User-Agent is printable ASCII: app name and version as tokens, the rest as comment text")
    func userAgentSanitised() {
        for (app, device, expected) in Self.userAgentCases {
            let userAgent = UserAgent.make(appName: app.0, appVersion: app.1, platform: device.0, osVersion: device.1, device: device.2)
            #expect(userAgent == "\(expected) MOS-iOS/\(MOSVersion)")
        }
    }

    @Test("a blank app name or version constructs, and the User-Agent says app for each")
    func blankAppInfo() async throws {
        let mos = try MOS(config: MOSConfig(publicKey: TestKeys.publicKey, surface: "s", app: MOSConfig.App(name: " ", version: "")))
        #expect(await mos.userAgent.hasPrefix("app/app ("))
    }

    @Test("the decision body: surface, identity, resource with meta and extra merged, nothing refused under a public key")
    func decisionBody() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", apiBaseURL: "https://api.example.com/")
        _ = await harness.mos.decide(resource: Resource(id: "article/1", meta: ["section": "sport"], extra: ["fullPath": "/sport/1", "id": "ignored"]))
        let request = harness.transport.requests.first
        #expect(request?.url.absoluteString == "https://api.example.com/api/v1/surface-decisions")
        #expect(request?.timeout == 5)
        #expect(request?.json == [
            "surfaceSlug": "app-paywall",
            "identity": ["anonymousIdentifier": "mos-anon-v1-abc"],
            "resource": ["id": "article/1", "meta": ["section": "sport"], "fullPath": "/sport/1"],
            "properties": ["platform": "ios"],
        ])
    }

    @Test("sk_ refusal: construction throws for anything but a pk_ key and logs config:invalid-key")
    func secretKeyRefused() {
        for key in ["sk_live_env_secret", "pk-live", "", "PK_live_env_secret"] {
            let logs = LogRecorder()
            #expect(throws: MOSError.invalidPublicKey) {
                try MOS(config: MOSConfig(publicKey: key, surface: "s", app: MOSConfig.App(name: "A", version: "1"), onLog: logs.onLog))
            }
            #expect(logs.codes == ["config:invalid-key"])
            if !key.isEmpty { #expect(!logs.all.contains { $0.description.contains(key) }) }
        }
    }

    @Test("429 maps to rateLimited, with or without an envelope, and serves the cache")
    func rateLimited() async {
        for response in [HTTPResponse.fixture("error-429.json", status: 429), .fixture("error-429.json"), .text("slow down", status: 429)] {
            let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", cached: [Decisions.entry()], handler: { _ in response })
            let result = await harness.decide("article/1")
            #expect(result.failure?.reason == .rateLimited)
            #expect(result.source == .cache(ageMs: 0))
            #expect(harness.transport.count == 1)
        }
    }

    @Test("invalid JSON: invalidJSON on a 2xx, httpError otherwise")
    func invalidJSON() async {
        let ok = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .text("<html>", status: 200) })
        #expect(await ok.decide().failure == Failure(reason: .invalidJSON, status: 200, message: "The response body is not JSON"))
        let gateway = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .text("<html>", status: 502) })
        #expect(await gateway.decide().failure == Failure(reason: .httpError, status: 502, message: "HTTP 502"))
        // Logged as the Android SDK logs it.
        #expect(Failure.Reason.invalidJSON.rawValue == "invalidJson")
    }

    @Test("an error envelope on a 200 is an API error")
    func errorEnvelopeOn200() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .fixture("error-404.json") })
        let result = await harness.decide()
        #expect(result.failure == Failure(reason: .apiError, status: 200, statusCode: 404, message: "Surface with slug 'nope' not found"))
        #expect(result.decision == nil)
        #expect(harness.cache.entries.isEmpty)
    }

    @Test("an error envelope without a statusCode takes the HTTP status; one without an envelope leaves it nil")
    func envelopeWithoutStatusCode() async {
        let envelope = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .json(["status": "error", "message": "bad"], status: 400) })
        #expect(await envelope.decide().failure == Failure(reason: .apiError, status: 400, statusCode: 400, message: "bad"))
        let bare = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .json(["detail": "upstream"], status: 503) })
        #expect(await bare.decide().failure?.statusCode == nil)
    }

    @Test("a 2xx without the success shape is an invalid response")
    func invalidResponse() async {
        for body: JSONValue in [["status": "success"], ["status": "success", "identity": ["identifier": "x"]], [1, 2], "text"] {
            let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .json(body) })
            #expect(await harness.decide().failure?.reason == .invalidResponse)
        }
    }

    @Test("a non-2xx JSON body without an envelope is an HTTP error")
    func nonEnvelopeHttpError() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .json(["detail": "upstream"], status: 503) })
        #expect(await harness.decide().failure == Failure(reason: .httpError, status: 503, message: "HTTP 503"))
    }

    @Test("an unusable base URL fails the request without throwing")
    func invalidBaseUrl() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", apiBaseURL: "not a url")
        let result = await harness.decide()
        #expect(result.failure?.reason == .requestFailed)
        #expect(harness.transport.count == 0)
    }

    @Test("requestTimeout reaches the transport")
    func requestTimeout() async {
        let transport = FakeTransport()
        let mos = try! MOS(config: MOSConfig(
            publicKey: TestKeys.publicKey, surface: "s", app: MOSConfig.App(name: "A", version: "1"),
            identity: MOSConfig.Identity(store: InMemoryIdentityStore(anonymousIdentifier: "a")),
            requestTimeout: .milliseconds(2_500),
            transport: transport
        ).with(clock: FakeClock()).with(cache: InMemoryDecisionCacheStore(), queue: InMemoryMeteringQueueStore()))
        _ = await mos.decide(resource: Resource(id: "r"))
        #expect(transport.requests.first?.timeout == 2.5)
    }

    @Test("a request prints, debug-prints and dumps without its body or identity header values")
    func requestDescriptionsRedact() async throws {
        let jwt = Tokens.jwt(sub: "user_42")
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        await harness.mos.identify(userJWT: jwt)
        await harness.decide()
        let sent = try #require(harness.transport.requests.first)
        // Identity headers the SDK does not send today, in any case, as a host transport might add them.
        let custom = HTTPRequest(
            url: sent.url,
            headers: sent.headers.merging([
                "x-mos-user-jwt": jwt, "X-MOS-Anonymous-Identifier": "mos-anon-v1-abc", "Cookie": "session=s3cr3t",
                "X-MOS-Key": "Bearer \(TestKeys.publicKey)",
            ]) { _, new in new },
            body: sent.body,
            timeout: 5
        )
        for request in [sent, custom] {
            var dumped = ""
            dump(request, to: &dumped)
            let printed = [request.description, request.debugDescription, "\(request)", String(reflecting: request), dumped]
            let secrets = [jwt, String(jwt.split(separator: ".")[1]), TestKeys.publicKey, "mos-anon-v1-abc", "s3cr3t", "userJwt"]
            for text in printed {
                for secret in secrets {
                    #expect(!text.contains(secret), "leaked \(secret) in \(text)")
                }
                #expect(text.contains("/api/v1/surface-decisions"))
                #expect(text.contains("X-MOS-Mobile-Version"))
                #expect(text.contains("ios/\(MOSVersion)"))
                #expect(text.contains("\(request.body.count) bytes redacted"))
            }
        }
    }
}
