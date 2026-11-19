import Foundation
import Testing
@testable import MonetizationOS

@Suite("Endpoints")
struct EndpointTests {
    static let key = "pk_live_abc_s3cr_et"

    private func harness(_ handler: @escaping FakeTransport.Handler = { _ in .json(["ok": true]) }, jwtProvider: (@Sendable () async -> String?)? = nil) -> Harness {
        Harness(jwtProvider: jwtProvider, publicKey: Self.key, handler: handler)
    }

    private func response(_ result: EndpointResult, sourceLocation: SourceLocation = #_sourceLocation) -> EndpointResponse? {
        guard case .response(let response) = result else {
            Issue.record("expected a response, got \(result)", sourceLocation: sourceLocation)
            return nil
        }
        return response
    }

    private func failure(_ result: EndpointResult, sourceLocation: SourceLocation = #_sourceLocation) -> Failure? {
        guard case .failed(let failure) = result else {
            Issue.record("expected a failure, got \(result)", sourceLocation: sourceLocation)
            return nil
        }
        return failure
    }

    @Test("endpoints: URL for org and namespaced calls, path segments and namespace encoded, query sorted")
    func urls() async {
        let harness = harness()
        _ = await harness.mos.callEndpoint(path: "/orders/recent")
        _ = await harness.mos.callEndpoint(path: "a b/ü?#&", query: ["z": "1 2", "a": "x&y=z", "m": "~-._"], namespace: "install 1/x")
        #expect(harness.transport.requests.map(\.url.absoluteString) == [
            "https://api.example.com/api/v1/envs/live_abc/endpoints/orders/recent",
            "https://api.example.com/api/v1/envs/live_abc/namespaces/install%201%2Fx/endpoints/a%20b/%C3%BC%3F%23%26?a=x%26y%3Dz&m=~-._&z=1%202",
        ])
    }

    @Test("endpoints: an empty, . or .. segment is refused without sending", arguments: [
        ("", nil), ("a//b", nil), ("a/", nil), ("../secrets", nil), ("a/../b", nil), ("//a", nil), ("ok", ""), ("ok", ".."),
        (".", nil), ("a/./b", nil), ("a/.", nil), ("ok", "."),
    ] as [(String, String?)])
    func refusedSegments(path: String, namespace: String?) async {
        let harness = harness()
        let failure = failure(await harness.mos.callEndpoint(path: path, namespace: namespace))
        #expect(failure?.reason == .requestFailed)
        #expect(harness.transport.count == 0)
        #expect(harness.logs.events("endpoint:error").first?.context["reason"] == "requestFailed")
    }

    @Test("endpoints: pathSegments encodes each segment whole, on callEndpoint and the app handle; bad segments are refused")
    func pathSegments() async {
        let harness = harness()
        _ = await harness.mos.callEndpoint(pathSegments: ["users", "a/b", "ü ?#"])
        _ = await harness.mos.app(namespace: "install_1").call(pathSegments: ["/x", "..a"])
        #expect(harness.transport.requests.map(\.url.absoluteString) == [
            "https://api.example.com/api/v1/envs/live_abc/endpoints/users/a%2Fb/%C3%BC%20%3F%23",
            "https://api.example.com/api/v1/envs/live_abc/namespaces/install_1/endpoints/%2Fx/..a",
        ])
        #expect(harness.logs.events("endpoint:success").first?.context["path"] == "users/a%2Fb/%C3%BC%20%3F%23")
        for segments in [[], [""], ["a", "."], ["..", "b"]] {
            #expect(failure(await harness.mos.callEndpoint(pathSegments: segments))?.reason == .requestFailed)
        }
        #expect(harness.transport.count == 2)
    }

    @Test("endpoints: each method is sent as given", arguments: EndpointMethod.allCases)
    func eachMethod(method: EndpointMethod) async {
        let harness = harness()
        let body: JSONValue? = method.allowsBody ? ["a": 1] : nil
        _ = await harness.mos.callEndpoint(path: "p", method: method, body: body)
        let request = harness.transport.requests.first
        #expect(request?.method == method.rawValue)
        #expect(request?.body == (body?.encoded() ?? Data()))
        #expect(request?.headers["Content-Type"] == (body == nil ? nil : "application/json"))
    }

    @Test("endpoints: a body is refused on GET and DELETE", arguments: [EndpointMethod.get, .delete])
    func bodyRefused(method: EndpointMethod) async {
        let harness = harness()
        #expect(failure(await harness.mos.callEndpoint(path: "p", method: method, body: ["a": 1]))?.reason == .requestFailed)
        #expect(harness.transport.count == 0)
    }

    @Test("endpoints: headers sent, including host headers such as Authorization")
    func headersSent() async {
        let harness = harness()
        _ = await harness.mos.callEndpoint(path: "p", body: ["a": 1], headers: ["Authorization": "Bearer user.jwt", "X-Trace": "t1", "accept": "text/plain"])
        let userAgent = await harness.mos.userAgent
        #expect(harness.transport.requests.first?.headers == [
            "X-MOS-Key": "Bearer \(Self.key)",
            "User-Agent": userAgent,
            "X-MOS-Mobile-Version": "ios/\(MOSVersion)",
            "accept": "text/plain",
            "Content-Type": "application/json",
            "Authorization": "Bearer user.jwt",
            "X-Trace": "t1",
        ])
        #expect(harness.logs.count("endpoint:header-ignored") == 0)

        _ = await harness.mos.callEndpoint(path: "p", method: .get)
        #expect(harness.transport.requests.last?.headers == [
            "X-MOS-Key": "Bearer \(Self.key)", "User-Agent": userAgent, "X-MOS-Mobile-Version": "ios/\(MOSVersion)", "Accept": "application/json",
        ])
    }

    @Test("endpoints: SDK-owned header names are dropped, case-insensitively, and logged")
    func ownedHeadersDropped() async {
        let harness = harness()
        let owned = [
            "x-mos-key": "Bearer pk_other", "User-Agent": "spoof", "X-MOS-MOBILE-VERSION": "9", "content-type": "text/plain", "Content-Length": "1",
            "X-MOS-User-Jwt": "spoof.jwt", "x-mos-anonymous-identifier": "mos-anon-v1-spoof",
        ]
        _ = await harness.mos.callEndpoint(path: "p", body: ["a": 1], headers: owned)
        let sent = harness.transport.requests.first?.headers ?? [:]
        #expect(sent["X-MOS-Key"] == "Bearer \(Self.key)")
        #expect(sent["Content-Type"] == "application/json")
        // The SDK sends no identity on endpoint calls, and a host cannot hand-set one.
        #expect(!sent.keys.contains { $0.lowercased() == "x-mos-user-jwt" || $0.lowercased() == "x-mos-anonymous-identifier" })
        #expect(sent.count == 5)
        let ignored = harness.logs.events("endpoint:header-ignored")
        #expect(Set(ignored.compactMap { $0.context["name"]?.stringValue }) == Set(owned.keys))
        #expect(ignored.allSatisfy { $0.level == .warn })
        #expect(!harness.logs.all.contains { $0.description.contains("pk_other") })
    }

    @Test("endpoints: app(namespace) is equivalent to callEndpoint with that namespace")
    func appEquivalence() async {
        let harness = harness()
        let app = harness.mos.app(namespace: "orders_1")
        #expect(app.namespace == "orders_1")
        let viaApp = await app.call(path: "sync", method: .put, body: ["a": 1], query: ["q": "1"], headers: ["X-A": "b"], timeout: .seconds(3))
        let direct = await harness.mos.callEndpoint(path: "sync", method: .put, body: ["a": 1], query: ["q": "1"], headers: ["X-A": "b"], namespace: "orders_1", timeout: .seconds(3))
        #expect(viaApp == direct)
        #expect(harness.transport.count == 2)
        #expect(harness.transport.requests[0] == harness.transport.requests[1])
    }

    @Test("endpoints: any status is a response with body, json, text and lowercased headers")
    func anyStatusIsAResponse() async {
        let cases: [HTTPResponse] = [
            .json(["linked": true], status: 201),
            .fixture("error-404.json", status: 404),
            .fixture("error-401.json", status: 401),
            .fixture("error-429.json", status: 429),
            .fixture("error-531.json", status: 531),
            HTTPResponse(status: 500, headers: ["X-Request-ID": "r1", "Content-Type": "application/json"], body: Data(#"{"status":"error"}"#.utf8)),
        ]
        for http in cases {
            let harness = harness { _ in http }
            let result = response(await harness.mos.callEndpoint(path: "p"))
            #expect(result?.status == http.status)
            #expect(result?.body == http.body)
            #expect(result?.json == JSONValue.parse(http.body))
            #expect(result?.text == String(decoding: http.body, as: UTF8.self))
            #expect(result?.isSuccess == (200..<300).contains(http.status))
            #expect(harness.transport.count == 1)
            if http.status == 201 {
                #expect(harness.logs.events("endpoint:success").map(\.context) == [["namespace": .null, "path": "p", "method": "POST", "status": 201]])
            } else {
                #expect(harness.logs.events("endpoint:error").first?.context["status"] == .int(http.status))
            }
        }
        let headers = EndpointResponse(status: 200, headers: ["X-Request-ID": "r1", "Set-Cookie": "a=1", "set-cookie": "b=2"], body: Data()).headers
        #expect(headers == ["x-request-id": "r1", "set-cookie": "a=1, b=2"])
    }

    @Test("endpoints: a non-JSON body has json nil and lossy text")
    func nonJSONBody() async {
        let bytes = Data("<html>ok".utf8) + Data([0xFF])
        let harness = harness { _ in HTTPResponse(status: 200, body: bytes) }
        let result = response(await harness.mos.callEndpoint(path: "p"))
        #expect(result?.json == nil)
        #expect(result?.text == "<html>ok\u{FFFD}")
        #expect(result?.body == bytes)
        #expect(response(await Harness(publicKey: Self.key, handler: { _ in HTTPResponse(status: 204, body: Data()) }).mos.callEndpoint(path: "p"))?.json == nil)
    }

    @Test("endpoints: no response is failed with requestFailed, timeout or notConfigured")
    func noResponseIsFailed() async {
        #expect(failure(await harness(networkDown).mos.callEndpoint(path: "p"))?.reason == .requestFailed)
        #expect(failure(await harness({ _ in throw URLError(.timedOut) }).mos.callEndpoint(path: "p"))?.reason == .timeout)
        let unconfigured = Harness(publicKey: "pk_test")
        #expect(failure(await unconfigured.mos.callEndpoint(path: "p"))?.reason == .notConfigured)
        #expect(unconfigured.logs.events("endpoint:error").first?.context["reason"] == "notConfigured")
    }

    @Test("endpoints: an explicit timeout is honoured exactly, else the full requestTimeout, even in fail-fast; neither enters it")
    func explicitTimeout() async {
        let harness = harness { _ in throw URLError(.timedOut) }
        _ = await harness.mos.callEndpoint(path: "p", timeout: .milliseconds(7_500))
        _ = await harness.mos.callEndpoint(path: "p")
        #expect(harness.logs.count("transport:degraded") == 0)
        _ = await harness.mos.decide(resource: Resource(id: "article/1"))
        #expect(harness.logs.count("transport:degraded") == 1)
        _ = await harness.mos.callEndpoint(path: "p", timeout: .milliseconds(7_500))
        _ = await harness.mos.callEndpoint(path: "p")
        #expect(harness.transport.requests.map(\.timeout) == [7.5, 5, 5, 7.5, 5])
    }

    @Test("endpoints: two identical concurrent calls make two transport calls", .timeLimit(.minutes(1)))
    func notCoalesced() async {
        let gate = Gate()
        let harness = harness { _ in
            await gate.wait()
            return .json(["ok": true])
        }
        async let first = harness.mos.callEndpoint(path: "p", body: ["a": 1])
        async let second = harness.mos.callEndpoint(path: "p", body: ["a": 1])
        await waitUntil { harness.transport.count == 2 }
        await gate.open()
        _ = await (first, second)
        #expect(harness.transport.count == 2)
    }

    @Test("endpoints: jwtProvider is not called and no identity is sent")
    func jwtProviderNotCalled() async {
        let calls = Box(0)
        let harness = harness(jwtProvider: {
            calls.set(calls.get() + 1)
            return Tokens.jwt(sub: "user_42")
        })
        _ = await harness.mos.callEndpoint(path: "p", body: ["a": 1])
        #expect(calls.get() == 0)
        #expect(harness.transport.requests.first?.headers["Authorization"] == nil)
        #expect(harness.transport.requests.first?.json == ["a": 1])
    }
}
