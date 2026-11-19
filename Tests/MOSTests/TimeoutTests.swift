import Foundation
import Testing
@testable import MonetizationOS

@Suite("Timeouts")
struct TimeoutTests {
    static let timedOut: FakeTransport.Handler = { _ in throw URLError(.timedOut) }

    @Test("fail-fast tier entry and use of 2s: after a timeout decisions use min(requestTimeout, 2s), redemptions and endpoints the full timeout")
    func failFastEntry() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: Self.timedOut)
        await harness.decide()
        await harness.decide()
        _ = await harness.mos.redeem(offerToken: Tokens.offer(expirationMsUtc: nil))
        _ = await harness.mos.callEndpoint(path: "registration", body: [:])
        await harness.decide()
        #expect(harness.transport.requests.map(\.timeout) == [5, 2, 5, 5, 2])
        let degraded = harness.logs.events("transport:degraded")
        #expect(degraded.count == 1)
        #expect(degraded.first?.level == .info)
        #expect(degraded.first?.context == ["timeoutMs": 2000])
    }

    @Test("fail-fast ignores redemptions and endpoint calls: their timeouts do not enter it, and a response to one still ends it")
    func failFastIgnoresRedemptionsAndEndpoints() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: Self.timedOut)
        _ = await harness.mos.redeem(offerToken: Tokens.offer(expirationMsUtc: nil))
        _ = await harness.mos.callEndpoint(path: "registration", body: [:])
        _ = await harness.mos.app(namespace: "notes").call(path: "create", body: [:])
        #expect(harness.logs.count("transport:degraded") == 0)
        await harness.decide()
        await harness.decide()
        #expect(harness.transport.requests.map(\.timeout) == [5, 5, 5, 5, 2])
        #expect(harness.logs.count("transport:degraded") == 1)

        // A workflow that takes 3 s: the full timeout gets its answer even in fail-fast, and the answer ends it.
        let slow: FakeTransport.Handler = { request in
            if request.timeout < 3 { throw URLError(.timedOut) }
            return request.url.path == "/api/v1/offer-redemptions" ? .fixture("redemption-none.json") : .json(["created": true])
        }
        harness.transport.respond(slow)
        guard case .redeemed = await harness.mos.redeem(offerToken: Tokens.offer(expirationMsUtc: nil)) else {
            Issue.record("expected the redemption's answer")
            return
        }
        harness.transport.respond(Self.timedOut)
        await harness.decide()
        harness.transport.respond(slow)
        guard case .response(let response) = await harness.mos.callEndpoint(path: "notes", body: [:]) else {
            Issue.record("expected the endpoint's response")
            return
        }
        #expect(response.status == 200)
        await harness.decide()
        #expect(harness.transport.requests.map(\.timeout).suffix(4) == [5, 5, 5, 5])
        #expect(harness.logs.count("transport:degraded") == 2)
        #expect(harness.logs.events("transport:recovered").map(\.context) == [["reason": "response"], ["reason": "response"]])

        // An explicit timeout is still used exactly.
        _ = await harness.mos.callEndpoint(path: "notes", body: [:], timeout: .seconds(9))
        #expect(harness.transport.requests.last?.timeout == 9)
    }

    @Test("fail-fast tier keeps a requestTimeout already under 2s")
    func failFastKeepsShorterTimeout() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", requestTimeout: .milliseconds(1_500), handler: Self.timedOut)
        await harness.decide()
        await harness.decide()
        #expect(harness.transport.requests.map(\.timeout) == [1.5, 1.5])
    }

    @Test("fail-fast tier recovery on response: any HTTP status ends it")
    func failFastRecoversOnResponse() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: Self.timedOut)
        await harness.decide()
        harness.transport.respond { _ in .text("down", status: 503) }
        await harness.decide()
        await harness.decide()
        #expect(harness.transport.requests.map(\.timeout) == [5, 2, 5])
        #expect(harness.logs.events("transport:recovered").map(\.context) == [["reason": "response"]])
        #expect(harness.logs.events("transport:recovered").first?.level == .info)
    }

    @Test("fail-fast tier expiry after 10 minutes on the injected clock")
    func failFastExpires() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: Self.timedOut)
        await harness.decide()
        harness.transport.respond { _ in throw URLError(.notConnectedToInternet) }
        harness.clock.advance(ms: 10 * TestTime.minute - 1)
        await harness.decide()
        harness.clock.advance(ms: 1)
        // Measured from entering fail-fast, not from the last call.
        await harness.decide()
        #expect(harness.transport.requests.map(\.timeout) == [5, 2, 5])
        #expect(harness.logs.events("transport:recovered").map(\.context) == [["reason": "expired"]])

        // A later timeout restarts the window.
        harness.transport.respond(Self.timedOut)
        await harness.decide()
        await harness.decide()
        #expect(harness.transport.requests.map(\.timeout).suffix(2) == [5, 2])
        #expect(harness.logs.count("transport:degraded") == 2)
    }

    @Test("fail-fast window runs from entry: a timeout inside it does not extend it, so a slow network gets the full timeout back")
    func failFastWindowFromEntry() async {
        // The network answers in 3 s: only the full 5 s timeout gets a response.
        let slow: FakeTransport.Handler = { request in
            if request.timeout < 3 { throw URLError(.timedOut) }
            return .json(Decisions.make())
        }
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: Self.timedOut)
        await harness.decide()  // enters fail-fast
        harness.transport.respond(slow)
        harness.clock.advance(ms: 9 * TestTime.minute)
        #expect(await harness.decide(policy: .networkOnly).source == .unavailable)
        harness.clock.advance(ms: TestTime.minute)  // ten minutes after entry, one after the last timeout
        #expect(await harness.decide(policy: .networkOnly).source == .network)
        #expect(harness.transport.requests.map(\.timeout) == [5, 2, 5])
        #expect(harness.logs.count("transport:degraded") == 1)
        #expect(harness.logs.events("transport:recovered").map(\.context) == [["reason": "expired"]])
    }

    @Test("fail-fast window: a timeout on the first full-timeout call after it re-enters with a new window")
    func failFastReentersWithNewWindow() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: Self.timedOut)
        await harness.decide()
        harness.clock.advance(ms: 10 * TestTime.minute)
        await harness.decide()  // full timeout, times out: a new window from here
        harness.clock.advance(ms: 9 * TestTime.minute)
        await harness.decide()  // inside the new window
        harness.clock.advance(ms: TestTime.minute)
        await harness.decide()  // the new window ended
        #expect(harness.transport.requests.map(\.timeout) == [5, 5, 2, 5])
        #expect(harness.logs.count("transport:degraded") == 3)
        #expect(harness.logs.events("transport:recovered").map(\.context) == [["reason": "expired"], ["reason": "expired"]])
    }

    @Test("the deadline returns timedOut on time even when the operation ignores cancellation")
    func deadlineIgnoresUncooperativeOperation() async {
        let gate = Gate()
        let started = ContinuousClock.now
        await #expect(throws: URLError(.timedOut)) {
            try await Deadline.run(seconds: 0.2) {
                await gate.wait()
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        await gate.open()
    }

    @Test("the deadline passes through a result that arrives first")
    func deadlinePassesResult() async throws {
        #expect(try await Deadline.run(seconds: 5) { 42 } == 42)
        await #expect(throws: URLError(.badURL)) {
            try await Deadline.run(seconds: 5) { () async throws -> Int in throw URLError(.badURL) }
        }
    }
}
