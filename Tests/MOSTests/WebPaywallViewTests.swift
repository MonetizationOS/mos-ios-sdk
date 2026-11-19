import Foundation
import os
import Testing
import WebKit
@testable import MonetizationOS
@testable import MonetizationOSUI

private final class Recorder: Sendable {
    private let events = OSAllocatedUnfairLock<[String]>(initialState: [])
    func add(_ event: String) { events.withLock { $0.append(event) } }
    var all: [String] { events.withLock { $0 } }
}

private struct Prices: PriceProvider {
    func prices(productIDs: Set<String>) async -> [String: StorePrice] {
        ["monthly": StorePrice(displayPrice: "$5.99", displayPeriod: "month")]
    }
}

@MainActor
@Suite("Web paywall view")
struct WebPaywallViewTests {
    @Test("web paywall view: loads, fills prices, redeems, opens links, blocks the rest", .timeLimit(.minutes(1)))
    func endToEnd() async throws {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .fixture("redemption-none.json") })
        let recorder = Recorder()
        let coordinator = WebPaywallCoordinator(actions: WebPaywallActions(
            mos: harness.mos,
            priceProvider: Prices(),
            onRedemption: { result in recorder.add("redeemed:\(result)") },
            onClose: { recorder.add("close") },
            onOpenURL: { recorder.add("open:\($0.absoluteString)") }
        ))
        let webView = WebPaywallRepresentable.makeWebView(coordinator)
        let html = """
        <span id="price" data-mos-product="monthly">£4.99</span>
        <span id="intro" data-mos-product="monthly" data-mos-price="intro-display-price">none</span>
        <button id="buy" data-mos-redeem="tok.en.x">Buy</button>
        <iframe src="https://example.invalid/ad"></iframe>
        <a id="terms-link" href="#terms">Terms</a><p id="terms">Terms</p>
        """
        coordinator.load(WebPaywall.document(html: html), into: webView)
        await waitUntil { harness.logs.count("webpaywall:prices-filled") == 1 }
        #expect(harness.logs.events("webpaywall:prices-filled").first?.context == ["filled": 1, "missing": 1])

        func evaluate(_ script: String) async -> String? {
            await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(script) { result, _ in continuation.resume(returning: result as? String) }
            }
        }
        #expect(await evaluate("document.getElementById('price').textContent") == "$5.99")
        #expect(await evaluate("document.getElementById('intro').textContent") == "none")
        #expect(await evaluate("String(document.getElementById('intro').hasAttribute('data-mos-price-missing'))") == "true")

        _ = await evaluate("document.getElementById('buy').click()")
        await waitUntil { recorder.all.count == 1 }
        #expect(recorder.all.first?.hasPrefix("redeemed:") == true)
        #expect(harness.transport.requests(to: "/api/v1/offer-redemptions").first?.json["offerToken"] == "tok.en.x")
        #expect(harness.logs.count("webpaywall:redeem") == 1)
        #expect(!harness.logs.all.contains { $0.description.contains("tok.en.x") })

        // A fragment-only navigation stays in the document.
        _ = await evaluate("document.getElementById('terms-link').click()")
        for _ in 0..<200 where await evaluate("location.hash") != "#terms" {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await evaluate("location.href") == "about:blank#terms")
        #expect(recorder.all.count == 1)

        _ = await evaluate("location.href = 'https://example.com/terms'")
        await waitUntil { recorder.all.count == 2 }
        _ = await evaluate("location.href = 'mos://close'")
        await waitUntil { recorder.all.count == 3 }
        _ = await evaluate("location.href = 'mos://purchase?id=1'")
        await waitUntil { harness.logs.count("webpaywall:navigation-blocked") == 2 }
        // The iframe's sub-frame load is blocked, not opened.
        #expect(Set(harness.logs.events("webpaywall:navigation-blocked").map(\.context)) == [["scheme": "https"], ["scheme": "mos"]])
        #expect(Array(recorder.all.dropFirst()) == ["open:https://example.com/terms", "close"])
        #expect(await evaluate("document.getElementById('price').textContent") == "$5.99")
        #expect(harness.logs.count("webpaywall:loaded") == 1)
    }

    private func evaluate(_ webView: WKWebView, _ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in continuation.resume(returning: result as? String) }
        }
    }

    @Test("web paywall view: a load replaced before its policy check still shows the newest document", arguments: [0, 1, 5, 20])
    func overlappingLoads(gapMs: Int) async throws {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        let coordinator = WebPaywallCoordinator(actions: WebPaywallActions(
            mos: harness.mos, priceProvider: nil, onRedemption: { _ in }, onClose: {}, onOpenURL: { _ in }
        ))
        let webView = WebPaywallRepresentable.makeWebView(coordinator)
        coordinator.load(WebPaywall.document(html: "<p id=\"marker\">A</p>"), into: webView)
        if gapMs > 0 { try await Task.sleep(for: .milliseconds(gapMs)) }
        coordinator.load(WebPaywall.document(html: "<p id=\"marker\">B</p>"), into: webView)
        var shown: String?
        for _ in 0..<400 where shown != "B" {
            try await Task.sleep(for: .milliseconds(5))
            shown = await evaluate(webView, "document.getElementById('marker') && document.getElementById('marker').textContent")
        }
        #expect(shown == "B")
    }

    @Test("web paywall view: a crashed page reloads once; a second crash within 30 s closes", .timeLimit(.minutes(1)))
    func contentProcessTermination() async throws {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        let recorder = Recorder()
        let coordinator = WebPaywallCoordinator(actions: WebPaywallActions(
            mos: harness.mos, priceProvider: nil, onRedemption: { _ in }, onClose: { recorder.add("close") }, onOpenURL: { _ in }
        ))
        let start = ContinuousClock.now
        var now = start
        coordinator.now = { now }
        let webView = WebPaywallRepresentable.makeWebView(coordinator)
        coordinator.load(WebPaywall.document(html: "<p>crashy</p>"), into: webView)
        await waitUntil { harness.logs.count("webpaywall:loaded") == 1 }
        let terminated: @Sendable () -> [LogEvent] = { harness.logs.events("webpaywall:process-terminated") }

        coordinator.webViewWebContentProcessDidTerminate(webView)
        await waitUntil { harness.logs.count("webpaywall:loaded") == 2 }
        #expect(terminated().map(\.context) == [["action": "reload"]])
        #expect(terminated().first?.level == .warn)

        // 30 s after the last one is not "again": it reloads.
        now = start + .seconds(30)
        coordinator.webViewWebContentProcessDidTerminate(webView)
        await waitUntil { harness.logs.count("webpaywall:loaded") == 3 }

        now = start + .seconds(59)
        coordinator.webViewWebContentProcessDidTerminate(webView)
        await waitUntil { terminated().count == 3 }
        #expect(terminated().map(\.context) == [["action": "reload"], ["action": "reload"], ["action": "close"]])
        #expect(recorder.all == ["close"])
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.logs.count("webpaywall:loaded") == 3)
    }

    @Test("web paywall view: a redeem is ignored while another is in flight, and works again after it", .timeLimit(.minutes(1)))
    func redeemInFlight() async throws {
        let gate = Gate()
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in
            await gate.wait()
            return .fixture("redemption-none.json")
        })
        let recorder = Recorder()
        let coordinator = WebPaywallCoordinator(actions: WebPaywallActions(
            mos: harness.mos, priceProvider: nil,
            onRedemption: { result in recorder.add("redeemed:\(result)") }, onClose: {}, onOpenURL: { _ in }
        ))
        let webView = WebPaywallRepresentable.makeWebView(coordinator)
        coordinator.load(WebPaywall.document(html: "<button id=\"buy\" data-mos-redeem=\"tok.en.x\">Buy</button>"), into: webView)
        await waitUntil { await self.evaluate(webView, "String(!!document.getElementById('buy'))") == "true" }

        _ = await evaluate(webView, "document.getElementById('buy').click()")
        await waitUntil { harness.logs.count("webpaywall:redeem") == 1 }
        _ = await evaluate(webView, "document.getElementById('buy').click()")
        try await Task.sleep(for: .milliseconds(100))
        await gate.open()
        await waitUntil { recorder.all.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.all.count == 1)

        _ = await evaluate(webView, "document.getElementById('buy').click()")
        await waitUntil { recorder.all.count == 2 }
    }
}
