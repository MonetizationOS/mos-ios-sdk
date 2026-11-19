import MonetizationOS
import SwiftUI
import WebKit

/// Shows an `Experience.web` paywall in a web view. The page reaches the app only by
/// navigating: `mos://redeem?token=` redeems through `mos`, `mos://close` closes, and
/// `http`/`https` links go to `onOpenURL`. Everything else is blocked. If the page's web content
/// process ends, the page reloads once; if it ends again within 30 seconds, the view calls `onClose`.
public struct MOSWebPaywallView: View {
    let html: String
    let mos: MOS
    let priceProvider: (any PriceProvider)?
    let baseCSS: String?
    let onRedemption: @MainActor (RedemptionResult) -> Void
    let onClose: @MainActor () -> Void
    let onOpenURL: (@MainActor (URL) -> Void)?
    @Environment(\.openURL) private var openURL

    /// `onOpenURL` defaults to the environment's `openURL`, i.e. the system browser.
    public init(
        html: String,
        mos: MOS,
        priceProvider: (any PriceProvider)? = nil,
        baseCSS: String? = nil,
        onRedemption: @escaping @MainActor (RedemptionResult) -> Void,
        onClose: @escaping @MainActor () -> Void,
        onOpenURL: (@MainActor (URL) -> Void)? = nil
    ) {
        self.html = html
        self.mos = mos
        self.priceProvider = priceProvider
        self.baseCSS = baseCSS
        self.onRedemption = onRedemption
        self.onClose = onClose
        self.onOpenURL = onOpenURL
    }

    public var body: some View {
        let openURL = openURL
        WebPaywallRepresentable(
            document: WebPaywall.document(html: html, baseCSS: baseCSS),
            actions: WebPaywallActions(
                mos: mos,
                priceProvider: priceProvider,
                onRedemption: onRedemption,
                onClose: onClose,
                onOpenURL: onOpenURL ?? { openURL($0) }
            )
        )
    }
}

struct WebPaywallActions {
    let mos: MOS
    let priceProvider: (any PriceProvider)?
    let onRedemption: @MainActor (RedemptionResult) -> Void
    let onClose: @MainActor () -> Void
    let onOpenURL: @MainActor (URL) -> Void
}

#if os(iOS)
typealias PlatformViewRepresentable = UIViewRepresentable
#elseif os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

struct WebPaywallRepresentable: PlatformViewRepresentable {
    let document: String
    let actions: WebPaywallActions

    func makeCoordinator() -> WebPaywallCoordinator {
        WebPaywallCoordinator(actions: actions)
    }

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { Self.makeWebView(context.coordinator) }
    func updateUIView(_ webView: WKWebView, context: Context) { update(webView, context.coordinator) }
    #elseif os(macOS)
    func makeNSView(context: Context) -> WKWebView { Self.makeWebView(context.coordinator) }
    func updateNSView(_ webView: WKWebView, context: Context) { update(webView, context.coordinator) }
    #endif

    /// No persistent storage, no message handlers, no pop-ups: the page has no bridge to native.
    static func makeWebView(_ coordinator: WebPaywallCoordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsLinkPreview = false
        webView.navigationDelegate = coordinator
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
        return webView
    }

    private func update(_ webView: WKWebView, _ coordinator: WebPaywallCoordinator) {
        coordinator.actions = actions
        coordinator.load(document, into: webView)
    }
}

@MainActor
final class WebPaywallCoordinator: NSObject, WKNavigationDelegate {
    var actions: WebPaywallActions
    private var loadedDocument: String?
    /// loadHTMLString navigations whose about:blank policy check is still to come; a replaced
    /// load may or may not reach it, so the latest load's commit or failure zeroes the count.
    private var pendingInitialLoads = 0
    private var latestLoad: WKNavigation?
    private var isRedeeming = false
    /// Bumped per load so a price fill for a replaced document is dropped.
    private var generation = 0
    /// When the web content process last terminated: a page that crashes again within
    /// `terminationWindow` closes instead of reloading forever.
    private var lastTermination: ContinuousClock.Instant?
    static let terminationWindow: Duration = .seconds(30)
    /// Injectable for tests.
    var now: @MainActor () -> ContinuousClock.Instant = { .now }

    init(actions: WebPaywallActions) {
        self.actions = actions
    }

    func load(_ document: String, into webView: WKWebView) {
        guard document != loadedDocument else { return }
        loadedDocument = document
        generation += 1
        pendingInitialLoads += 1
        // A nil base URL gives the document a null origin.
        latestLoad = webView.loadHTMLString(document, baseURL: nil)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // No target frame is a new-window request, which we treat as a main-frame link.
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        let isInitialLoad = pendingInitialLoads > 0 && action.request.url?.absoluteString == "about:blank"
        let navigation = WebPaywall.classify(action.request.url, isMainFrame: isMainFrame, isInitialLoad: isInitialLoad)
        if navigation == .load {
            if isInitialLoad { pendingInitialLoads -= 1 }
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        switch navigation {
        case .load:
            break
        case .redeem(let token):
            // A double tap must not reach the host twice (it may start a purchase per call).
            guard !isRedeeming else { return }
            isRedeeming = true
            Task {
                defer { isRedeeming = false }
                // The token is never logged.
                await actions.mos.log(.info, "webpaywall:redeem", "The web paywall asked to redeem an offer.")
                actions.onRedemption(await actions.mos.redeem(offerToken: token))
            }
        case .close:
            actions.onClose()
        case .openURL(let url):
            actions.onOpenURL(url)
        case .blocked(let scheme):
            Task { await actions.mos.log(.warn, "webpaywall:navigation-blocked", "The web paywall blocked a navigation.", ["scheme": .string(scheme)]) }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if navigation === latestLoad { pendingInitialLoads = 0 }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if navigation === latestLoad { pendingInitialLoads = 0 }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if navigation === latestLoad { pendingInitialLoads = 0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let generation = generation
        Task {
            await actions.mos.log(.debug, "webpaywall:loaded", "The web paywall finished loading.")
            let productIDs = WebPaywall.productIDs(await evaluate(WebPaywall.collectProductIDsScript, in: webView))
            let script = await actions.mos.webPaywallPriceScript(productIDs: productIDs, provider: actions.priceProvider)
            guard generation == self.generation else { return }
            let counts = WebPaywall.fillCounts(await evaluate(script, in: webView))
            await actions.mos.log(.info, "webpaywall:prices-filled", "Filled the web paywall's prices.", [
                "filled": .int(counts.filled), "missing": .int(counts.missing),
            ])
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let terminatedAt = now()
        let again = lastTermination.map { terminatedAt - $0 < Self.terminationWindow } ?? false
        lastTermination = terminatedAt
        let message = again ? "The web paywall's content process ended again; closing." : "The web paywall's content process ended; reloading."
        let action: JSONValue = again ? "close" : "reload"
        Task { await actions.mos.log(.warn, "webpaywall:process-terminated", message, ["action": action]) }
        if again {
            actions.onClose()
            return
        }
        guard let document = loadedDocument else { return }
        loadedDocument = nil
        load(document, into: webView)
    }

    /// Runs in an isolated world so page scripts cannot tamper with the fill.
    private func evaluate(_ script: String, in webView: WKWebView) async -> JSONValue? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                let data = (try? result.get()).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
                continuation.resume(returning: data.flatMap(JSONValue.parse))
            }
        }
    }
}
