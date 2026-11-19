import Foundation

/// The web paywall's logic without a web view: the document, what each navigation means, and
/// the price scripts. `MOSWebPaywallView` (MonetizationOSUI) drives it. The document and scripts
/// are the files in `shared/`, which the Android SDK ships too.
package enum WebPaywall {
    /// What a navigation in the paywall means. Everything but `.load` is cancelled.
    package enum Navigation: Sendable, Equatable {
        /// The initial load of the document, or a fragment-only navigation within it.
        case load
        case redeem(token: String)
        case close
        /// An `http`/`https` main-frame link, for the host to open outside the paywall.
        case openURL(URL)
        case blocked(scheme: String)
    }

    static func shared(_ name: String, _ ext: String) -> String {
        // Only a stale incremental build has been seen to drop them; a clean build restores them.
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "shared"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { preconditionFailure("The MOS resource shared/\(name).\(ext) is missing from the MOS bundle.") }
        return text
    }

    static let template = shared("document", "html")
    static let pageScript = shared("page", "js")
    /// Evaluates to the distinct `data-mos-product` ids on the page, as an array.
    package static let collectProductIDsScript = shared("collect-product-ids", "js")
    static let fillPricesFunction = shared("fill-prices", "js").trimmingCharacters(in: .whitespacesAndNewlines)

    /// Wraps experience HTML in the shared document. `baseCSS` is the host's; `</` in it is
    /// written `<\/`, the same to CSS, so it cannot end its style element.
    package static func document(html: String, baseCSS: String? = nil) -> String {
        let css = (baseCSS ?? "").replacingOccurrences(of: "</", with: "<\\/")
        // Split on the markers rather than replace them, so inserted text is never searched.
        let (head, afterCSS) = split(Substring(template), at: "/*base-css*/")
        let (styles, afterScript) = split(afterCSS, at: "/*page-script*/")
        let (beforeHTML, tail) = split(afterScript, at: "<!--html-->")
        return String(head) + css + styles + pageScript + beforeHTML + html + tail
    }

    private static func split(_ text: Substring, at marker: String) -> (Substring, Substring) {
        let range = text.range(of: marker)!
        return (text[..<range.lowerBound], text[range.upperBound...])
    }

    /// `isInitialLoad` is true only for the document the view itself loaded.
    package static func classify(_ url: URL?, isMainFrame: Bool, isInitialLoad: Bool) -> Navigation {
        if isInitialLoad, isMainFrame { return .load }
        let scheme = url?.scheme?.lowercased() ?? ""
        guard isMainFrame, let url else { return .blocked(scheme: scheme) }
        // In-page anchors of the null-origin document: about:blank#x, which iOS 26 WebKit reports as about:blank%23x.
        let absolute = url.absoluteString.lowercased()
        if absolute.hasPrefix("about:blank#") || absolute.hasPrefix("about:blank%23") { return .load }
        switch scheme {
        case "mos":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            switch components?.host?.lowercased() {
            case "redeem":
                if let token = components?.queryItems?.first(where: { $0.name == "token" })?.value, !token.isEmpty {
                    return .redeem(token: token)
                }
            case "close":
                return .close
            default:
                break
            }
            return .blocked(scheme: scheme)
        case "http", "https":
            return .openURL(url)
        default:
            return .blocked(scheme: scheme)
        }
    }

    /// The shared fill function called with `[id, {field: value}]` pairs as a script-safe JSON
    /// literal, never spliced strings. Evaluates to `{filled, missing}`.
    static func priceFillScript(_ prices: [String: StorePrice]) -> String {
        let pairs = JSONValue.array(prices.keys.sorted().map { id in
            let price = prices[id]!
            var fields: [String: JSONValue] = ["display-price": .string(price.displayPrice)]
            if let period = price.displayPeriod { fields["display-period"] = .string(period) }
            if let intro = price.introductoryDisplayPrice { fields["intro-display-price"] = .string(intro) }
            return [.string(id), .object(fields)]
        })
        return "\(fillPricesFunction)(\(scriptSafeJSON(pairs)))"
    }

    /// JSON that is safe inside a script element and as a JavaScript literal: `<`, `>`, `&`
    /// and the two line separators are escaped. They can only occur inside JSON strings.
    static func scriptSafeJSON(_ value: JSONValue) -> String {
        var out = ""
        for scalar in value.jsonString.unicodeScalars {
            switch scalar {
            case "<": out += "\\u003c"
            case ">": out += "\\u003e"
            case "&": out += "\\u0026"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Reads the `{filled, missing}` the fill script evaluates to.
    package static func fillCounts(_ result: JSONValue?) -> (filled: Int, missing: Int) {
        (result?["filled"]?.intValue ?? 0, result?["missing"]?.intValue ?? 0)
    }

    /// Reads the id array `collectProductIDsScript` evaluates to.
    package static func productIDs(_ result: JSONValue?) -> Set<String> {
        Set(result?.arrayValue?.compactMap { $0.stringValue.flatMap { $0.isEmpty ? nil : $0 } } ?? [])
    }
}

extension MOS {
    /// Asks the provider for the page's products and returns the fill script. No provider fills
    /// nothing, so every element is revealed with its fallback text.
    package func webPaywallPriceScript(productIDs: Set<String>, provider: (any PriceProvider)?) async -> String {
        let prices = productIDs.isEmpty ? [:] : await provider?.prices(productIDs: productIDs) ?? [:]
        return WebPaywall.priceFillScript(prices.filter { productIDs.contains($0.key) })
    }
}
