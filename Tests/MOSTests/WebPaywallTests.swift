import Foundation
import JavaScriptCore
import os
import Testing
@testable import MonetizationOS

/// Runs the paywall scripts in JavaScriptCore against a minimal fake DOM.
private final class FakePage {
    let context = JSContext()!

    /// `elements`: (data-mos-product, data-mos-price or nil, fallback text).
    init(_ elements: [(product: String, price: String?, text: String)] = []) {
        let specs = JSONValue.array(elements.map { element in
            var attrs: [String: JSONValue] = ["data-mos-product": .string(element.product)]
            if let price = element.price { attrs["data-mos-price"] = .string(price) }
            return ["attrs": .object(attrs), "text": .string(element.text)]
        })
        context.evaluateScript("""
        var classes = [], listeners = {}, timers = [], location = { href: '' };
        var elements = \(specs.jsonString).map(function (spec) {
          return { attrs: spec.attrs, textContent: spec.text,
            getAttribute: function (n) { return Object.prototype.hasOwnProperty.call(this.attrs, n) ? this.attrs[n] : null; },
            setAttribute: function (n, v) { this.attrs[n] = String(v); },
            removeAttribute: function (n) { delete this.attrs[n]; } };
        });
        var document = {
          querySelectorAll: function () { return elements; },
          documentElement: { classList: { add: function (c) { classes.push(c); } } },
          addEventListener: function (type, fn) { listeners[type] = fn; }
        };
        function setTimeout(fn, ms) { timers.push({ fn: fn, ms: ms }); }
        """)
    }

    /// The script's value as JSON, as the web view hands it back.
    @discardableResult
    func run(_ script: String) -> JSONValue? {
        let value = context.evaluateScript(script)
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        let json = context.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [value as Any])
        return json?.isString == true ? JSONValue.parse(Data(json!.toString().utf8)) : nil
    }

    func json(_ expression: String) -> JSONValue? { run(expression) }
}

private final class FakePriceProvider: PriceProvider {
    let prices: [String: StorePrice]
    private let asked = OSAllocatedUnfairLock<[Set<String>]>(initialState: [])

    init(_ prices: [String: StorePrice]) { self.prices = prices }

    func prices(productIDs: Set<String>) async -> [String: StorePrice] {
        asked.withLock { $0.append(productIDs) }
        return prices
    }

    var calls: [Set<String>] { asked.withLock { $0 } }
}

@Suite("Web paywall")
struct WebPaywallTests {
    @Test("web paywall: document shape and order")
    func documentShape() throws {
        let document = WebPaywall.document(html: "<div id=\"mos-x\">Wall</div>", baseCSS: "body{margin:0}</STYLE><script>bad()</script>")
        #expect(document.hasPrefix("<!doctype html>\n"))
        let pieces = [
            "<meta charset=\"utf-8\">",
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">",
            "color-scheme:light dark",
            "<style>body{margin:0}<\\/STYLE><script>bad()<\\/script></style>",
            "html:not(.mos-prices-ready) [data-mos-product]{visibility:hidden!important}",
            "<script>" + WebPaywall.pageScript + "</script>",
            "</head>",
            "<body>\n<div id=\"mos-x\">Wall</div>\n</body>",
        ]
        var cursor = document.startIndex
        for piece in pieces {
            let range = try #require(document.range(of: piece, range: cursor..<document.endIndex), "missing or out of order: \(piece)")
            cursor = range.upperBound
        }
        #expect(!document.lowercased().contains("</style><script>bad"))
        #expect(WebPaywall.document(html: "x").contains("<style></style>"))
    }

    @Test("web paywall: price elements are revealed by a 2 s timer when filling never finishes")
    func revealTimeout() {
        let page = FakePage()
        page.run(WebPaywall.pageScript)
        #expect(page.json("timers.map(function (t) { return t.ms; })") == [2000])
        #expect(page.json("classes") == [])
        page.run("timers[0].fn()")
        #expect(page.json("classes") == ["mos-prices-ready"])
    }

    @Test("web paywall: data-mos-redeem clicks navigate to mos://redeem with the token encoded")
    func redeemClickHandler() {
        let page = FakePage()
        page.run(WebPaywall.pageScript)
        page.run("""
        var prevented = false;
        var target = { closest: function () { return { getAttribute: function () { return 'a.b+c/d'; } }; } };
        listeners.click({ target: target, preventDefault: function () { prevented = true; } });
        """)
        #expect(page.json("location.href") == "mos://redeem?token=a.b%2Bc%2Fd")
        #expect(page.json("prevented") == true)
        #expect(WebPaywall.classify(URL(string: "mos://redeem?token=a.b%2Bc%2Fd"), isMainFrame: true, isInitialLoad: false) == .redeem(token: "a.b+c/d"))

        page.run("location.href = ''; listeners.click({ target: { closest: function () { return null; } }, preventDefault: function () {} });")
        #expect(page.json("location.href") == "")
        // An empty token navigates nowhere.
        page.run("listeners.click({ target: { closest: function () { return { getAttribute: function () { return ''; } }; } }, preventDefault: function () {} });")
        #expect(page.json("location.href") == "")
    }

    @Test("web paywall: navigation classification", arguments: [
        ("about:blank", true, true, .load),
        ("about:blank", false, true, .blocked(scheme: "about")),
        ("about:blank", true, false, .blocked(scheme: "about")),
        ("about:blank#terms", true, false, .load),
        ("about:blank%23terms", true, false, .load),
        ("ABOUT:BLANK#x", true, false, .load),
        ("about:blank#terms", false, false, .blocked(scheme: "about")),
        ("about:srcdoc#x", true, false, .blocked(scheme: "about")),
        ("mos://redeem?token=tok.en.x", true, false, .redeem(token: "tok.en.x")),
        ("MOS://REDEEM?token=t", true, false, .redeem(token: "t")),
        ("mos://redeem?other=1&token=t", true, false, .redeem(token: "t")),
        ("mos://redeem?token=", true, false, .blocked(scheme: "mos")),
        ("mos://redeem", true, false, .blocked(scheme: "mos")),
        ("mos://close", true, false, .close),
        ("mos://close?x=1", true, false, .close),
        ("mos://purchase?id=1", true, false, .blocked(scheme: "mos")),
        ("mos://redeem?token=t", false, false, .blocked(scheme: "mos")),
        ("https://example.com/terms", true, false, .openURL(URL(string: "https://example.com/terms")!)),
        ("http://example.com", true, false, .openURL(URL(string: "http://example.com")!)),
        ("https://example.com/ad", false, false, .blocked(scheme: "https")),
        ("file:///etc/passwd", true, false, .blocked(scheme: "file")),
        ("data:text/html,<p>x</p>", true, false, .blocked(scheme: "data")),
        ("javascript:alert(1)", true, false, .blocked(scheme: "javascript")),
        ("tel:123", true, false, .blocked(scheme: "tel")),
    ] as [(String, Bool, Bool, WebPaywall.Navigation)])
    func classification(url: String, isMainFrame: Bool, isInitialLoad: Bool, expected: WebPaywall.Navigation) {
        #expect(WebPaywall.classify(URL(string: url), isMainFrame: isMainFrame, isInitialLoad: isInitialLoad) == expected)
    }

    @Test("web paywall: a missing URL is blocked")
    func nilURL() {
        #expect(WebPaywall.classify(nil, isMainFrame: true, isInitialLoad: false) == .blocked(scheme: ""))
    }

    @Test("web paywall: price fill sets each field, marks missing ones, and reveals")
    func priceFill() {
        let page = FakePage([
            ("monthly", nil, "£4.99"),
            ("monthly", "display-period", "month"),
            ("monthly", "intro-display-price", "free"),
            ("annual", "intro-display-price", "none"),
            ("unknown", nil, "£1"),
            ("monthly", "bogus", "x"),
            ("constructor", nil, "c"),
        ])
        let script = WebPaywall.priceFillScript([
            "monthly": StorePrice(displayPrice: "$5.99", displayPeriod: "month", introductoryDisplayPrice: "$0.99"),
            "annual": StorePrice(displayPrice: "$49.99", displayPeriod: "year"),
        ])
        #expect(WebPaywall.fillCounts(page.run(script)) == (3, 4))
        #expect(page.json("elements.map(function (e) { return e.textContent; })") == ["$5.99", "month", "$0.99", "none", "£1", "x", "c"])
        #expect(page.json("elements.map(function (e) { return e.getAttribute('data-mos-price-missing') !== null; })")
            == [false, false, false, true, true, true, true])
        #expect(page.json("classes") == ["mos-prices-ready"])
    }

    @Test("web paywall: no prices keeps every fallback, marks it missing and reveals")
    func noPrices() {
        let page = FakePage([("monthly", nil, "£4.99")])
        #expect(WebPaywall.fillCounts(page.run(WebPaywall.priceFillScript([:]))) == (0, 1))
        #expect(page.json("elements[0].textContent") == "£4.99")
        #expect(page.json("classes") == ["mos-prices-ready"])
    }

    @Test("web paywall: price script escaping of </script>, quotes, backslashes and line separators")
    func priceScriptEscaping() throws {
        let nasty = "</script><script>alert(\"x\")</script>\\'\u{2028}`${1}`"
        let price = "\"$1\\\"</SCRIPT>\u{2029}"
        let script = WebPaywall.priceFillScript([nasty: StorePrice(displayPrice: price, displayPeriod: "'month'")])
        #expect(!script.lowercased().contains("</script"))
        #expect(!script.contains("\u{2028}") && !script.contains("\u{2029}"))
        let literal = try #require(script.range(of: ")(", options: .backwards).map { script[$0.upperBound...] })
        #expect(!literal.contains("<") && !literal.contains(">") && !literal.contains("&"))

        let page = FakePage([(nasty, nil, "fallback"), (nasty, "display-period", "fallback")])
        #expect(WebPaywall.fillCounts(page.run(script)) == (2, 0))
        #expect(page.json("elements.map(function (e) { return e.textContent; })") == [.string(price), "'month'"])
        #expect(page.json("typeof alert") == "undefined")
    }

    @Test("web paywall: product ids are collected once each")
    func collectProductIds() {
        let page = FakePage([("a", nil, ""), ("b", "display-period", ""), ("a", nil, ""), ("", nil, "")])
        #expect(WebPaywall.productIDs(page.run(WebPaywall.collectProductIDsScript)) == ["a", "b"])
        #expect(WebPaywall.productIDs(nil) == [])
        #expect(WebPaywall.fillCounts(nil) == (0, 0))
    }

    @Test("web paywall: price script asks the provider for the page's ids; no provider fills nothing")
    func priceScriptFromProvider() async {
        let harness = Harness()
        let provider = FakePriceProvider(["a": StorePrice(displayPrice: "$1"), "z": StorePrice(displayPrice: "$9")])
        let script = await harness.mos.webPaywallPriceScript(productIDs: ["a", "b"], provider: provider)
        #expect(provider.calls == [["a", "b"]])
        #expect(script == WebPaywall.priceFillScript(["a": StorePrice(displayPrice: "$1")]))
        #expect(await harness.mos.webPaywallPriceScript(productIDs: ["a"], provider: nil) == WebPaywall.priceFillScript([:]))
        _ = await harness.mos.webPaywallPriceScript(productIDs: [], provider: provider)
        #expect(provider.calls.count == 1)
        #expect(harness.transport.count == 0)
    }
}
