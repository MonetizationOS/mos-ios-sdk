<div align="center">
  <a href="https://monetizationos.com">
  <img alt="MonetizationOS logo" src="https://app.monetizationos.com/static/monetizationos-logo.png" height="48">
  </a>
  <h1>MonetizationOS iOS SDK</h1>
</div>

A native Swift MonetizationOS SDK. It runs in your iOS app, makes a surface decision against the MOS API with a **public key**, and keeps working offline with a decision cache and deferred metering. The Android SDK is [mos-android-sdk](https://github.com/MonetizationOS/mos-android-sdk) and the browser SDK is [mos-browser-sdk](https://github.com/MonetizationOS/mos-browser-sdk).

Version `0.9.0`, the first public release; breaking changes are allowed before 1.0. Changes per release are in [CHANGELOG.md](./CHANGELOG.md). Start with [`Examples/Showcase`](./Examples/Showcase), a SwiftUI app with one screen per use case that runs on bundled fixtures with no account.

## Install

Swift Package Manager, from a version tag. Requires iOS 18+ (macOS 15+).

```swift
.package(url: "https://github.com/MonetizationOS/mos-ios-sdk", from: "0.9.0"),
// target dependencies: .product(name: "MonetizationOS", package: "mos-ios-sdk"), and "MonetizationOSUI" for the web paywall view
```

Two products: `MonetizationOS` (the client) and `MonetizationOSUI` (the web paywall view, WebKit).

## Usage

Create one `MOS` per app, at launch, and keep it: two instances with keys for the same environment share the default cache, queue and meter files and Keychain entries, and overwrite each other's.

```swift
import MonetizationOS

let mos = try MOS(config: MOSConfig(
    publicKey: "pk_live_…",
    surface: "app-paywall",
    app: .init(name: "FutureHerald", version: "1.0"),
    identity: .init(jwtProvider: { await auth.currentToken() }),   // nil only when signed out; the last token if a refresh fails
    onLog: consoleLogger                                             // or your own logger
))

let result = await mos.decide(resource: Resource(id: "article/123", meta: ["section": "sport"]))
if result.hasAccess(feature: "article", property: "enabled") { /* show the article */ }
let paywall = result.decision?.surfaceProperties["article"]          // open JSON from the workflow
switch result.source {
case .network: break
case .cache, .fallback: break                                        // served offline; metering is queued
case .unavailable: break                                             // no decision; hasAccess used failOpen
@unknown default: break                                              // a source added in a later release
}

await mos.identify(userJWT: token)         // without a jwtProvider: at every launch and after sign-in; nil on sign-out
await mos.flush()                          // on foreground or when connectivity returns
let redemption = await mos.redeem(offerToken: offer.token)
```

### Configuration

`MOSConfig(…)` takes these; all but the first three have defaults.

| Key | Default | What it does |
| --- | --- | --- |
| `publicKey` | | **Required.** `pk_*` key; safe to ship in the app. `sk_` keys are refused. |
| `surface` | | **Required.** Surface slug. `decide(…, surface:)` overrides it per call. |
| `app` | | **Required.** App name and version, for the `User-Agent`. Each run of characters outside an HTTP token becomes `-`, and a blank name or version is sent as `app`. |
| `apiBaseURL` | `https://api.monetizationos.com` | MOS API base URL. |
| `identity` | anonymous, Keychain | `jwtProvider`, read fresh at each call; `store`, any `IdentityStore`, a key-value store for the anonymous identifier and the rest of the identity state; `claimKey`, the JWT claim that identifies a user (`sub`). See [Identity](#identity). |
| `offline` | 24 h TTL, fail-open | Cache `ttl`, `failOpen`, `fallbackToLatest`, `maxEntries` and `enforceMeters`. See [Offline cache and metering](#offline-cache-and-metering). |
| `requestTimeout` | 5 s | End to end per API call. After a timeout, decisions and counter updates use `min(requestTimeout, 2 s)` for ten minutes or until any response. Timeouts in those ten minutes don't extend them. Redemptions and endpoint calls always get the full timeout, and their own timeouts don't start the ten minutes. |
| `onLog` | discard | Structured events. See [Logging & observability](#logging--observability). |
| `transport` | `URLSession` | Bring your own `HTTPTransport`, for example to mock it in tests. |

## Identity

Resolution order, highest precedence first:

1. an explicit `mos.identify(userJWT:)`;
2. the `jwtProvider` closure;
3. anonymous: the persisted anonymous identifier, else the SDK asks the server to mint one and persists it in the Keychain.

`identify(userJWT:)` lives in memory only and does not survive a relaunch: call it at every launch before any other call, or use `jwtProvider`, which the SDK asks at each call. A `jwtProvider` that returns nil signs the user out for that call and purges the decision cache, so if a token refresh fails, return the last token. The first decision after a sign-in carries `properties.previousAnonymousIdentifier` so a workflow can link the two; the SDK sends it again on each decision until one is answered for the signed-in user.

Set `identity.claimKey` to the claim key of your JWT integration in MOS; it defaults to `sub`. The SDK keys a signed-in user's cache and queue by that claim's value, a string or a number, so a refreshed token for the same user keeps them. A token without it is keyed by the whole token, so every refresh looks like a new user: the cache is purged and queued counter updates can be dropped.

A decision for a JWT can come back anonymous, for an expired token or a server fallback. The SDK returns it (`identity.isAuthenticated` is false) but does not cache it or record its meter counts, so the signed-in user's entries stay theirs, and logs `cache:skipped`.

If the identity store does not keep a newly minted anonymous id (its `value(forKey:)` does not return it), the SDK uses that id from memory until the process ends, rather than minting one per decision, and logs `identity:store-failed`.

## Resource and components

Each decision sends a `Resource(id:meta:extra:)`. `extra` keys merge into the resource at the top level and are available in workflows as `resource.<key>`. Each decision also carries `properties.platform` (`ios`; the Android SDK sends `android`) so one surface's workflow can pick per-store copy.

`decide(…, components:)` runs only the named components of the surface: `[]` runs the surface workflow alone, and leaving it out runs them all.

```swift
let lesson = await mos.decide(resource: Resource(id: "lesson/42"), components: ["lesson-paywall"])
```

## Offline cache and metering

- Every decision is cached per `(surface, identity, resource, components)` for the TTL or until the earliest offer token in it expires, a web paywall's `mos://redeem` links and `data-mos-redeem` attributes included. On any failure the exact entry is served, else the latest for that surface, identity and components. `result.source` says which. `decide(…, policy:)` picks `networkFirst` (the default), `cacheFirst(maxAge:)`, `networkOnly` or `cacheOnly`.
- The cache never stores `identity.jwtClaims`, and its files are excluded from device backups.
- The default stores are per environment of the public key (`default` for a key that names none), so a staging and a production key in one install never share an anonymous id, cache, queue or meter counts. Files go in `Application Support/com.monetizationos.sdk/<environment>/`, and the default identity store, `KeychainIdentityStore(publicKey:)`, uses Keychain service `com.monetizationos.sdk.<environment>`. On macOS, where unsandboxed apps share both, the bundle id is added: `Application Support/<bundle id>/com.monetizationos.sdk/<environment>/` and `com.monetizationos.sdk.<bundle id>.<environment>`.
- A decision served from the cache counts as a read: it queues `counter-updates` for the meters it consumed. `flush()` sends them, and a successful network decision flushes in the background when anything is queued.
- Meters keep counting offline. Each network decision records every meter's count. Until the next one, a meter in a decision served from the cache shows that count plus the reads counted on this device, so `remainingUnits` goes down as the reader reads. A unique-resource meter counts each resource once.
- `offline.enforceMeters` (off by default) turns a meter's access off once those reads use it up: the meter comes back with `hasAccess` false and `lockedOffline` true, and nothing is queued. A resource already counted this period stays open even then, which is more lenient than the server: online, a used-up meter is off for every resource. The cached decision is the one that granted access, so it has no paywall for this: show your own screen, or one cached from a surface of its own.
- Until the next network decision the device can't see a meter's period reset or reads on other devices, so offline the count can run out early or late.

```swift
// Online, now and then: cache the offline-limit screen from a surface of its own.
_ = await mos.decide(resource: Resource(id: "offline-limit"), surface: "offline-limit")

// Offline, when a read comes back locked:
if case .meterable(let meter)? = result.decision?.features["article"]?.properties["enabled"], meter.lockedOffline {
    let limit = await mos.decide(resource: Resource(id: "offline-limit"), policy: .cacheOnly, surface: "offline-limit")
    // show limit's experience
}
```

## Paywalls

A workflow returns resolved experiences in its properties. `Experience` tells a native one (app JSON plus typed offers) from a web one (server-rendered HTML).

```swift
import MonetizationOS
import MonetizationOSUI

switch result.decision?.experience("paywall") {
case .native(_, _, let offers)?:
    // your SwiftUI paywall: copy from the experience, prices from your own store code, redeem(offer.token) on tap
case .web(let html)?:
    MOSWebPaywallView(html: html, mos: mos, priceProvider: myPrices,   // a PriceProvider backed by StoreKit
                      onRedemption: { handle($0) },                    // the same RedemptionResult redeem(offerToken:) returns
                      onClose: { dismiss() })
case nil: break
@unknown default: break                                                // a kind added in a later release
}

func handle(_ redemption: RedemptionResult) {
    switch redemption {
    case .redeemed(.navigate(let url, _), _, _): openURL(url)                             // http(s) or your own app's scheme only, see below
    case .redeemed(.custom(let type, let properties), _, _): purchase(type, properties)   // custom or custom:*, e.g. custom:storekit: your StoreKit flow
    case .redeemed(.noAction, _, _): Task { await refresh() }                             // decide again: the redemption cleared the cache
    case .declined(let message, _, _): show(message)                                      // the workflow refused it
    case .failed(let failure): show(failure.message)                                      // it may not have run; for a timeout or server error it may have, so check before retrying
    @unknown default: Task { await refresh() }                                            // an action added in a later release
    }
}
```

A redeemed offer clears the decision cache, as `clearCache()` does, so the next decision comes from the server. A `navigate` URL comes from your organization's redemption workflow: open it only if it is `http`, `https` or your own app's scheme.

Web paywall templates opt in with plain attributes: `data-mos-product="{{storeProductId}}"` on any element whose text should become the store's localized price (`data-mos-price="display-period"` for the period), and `<a href="mos://redeem?token={{mos-offer-token}}">` or `data-mos-redeem="{{mos-offer-token}}"` for the buy button. If the web content process ends, the view reloads the page once; if it ends again within 30 seconds, the view calls `onClose`. Both log `webpaywall:process-terminated`.

## Endpoints

`callEndpoint` calls your organization's MOS endpoints with the public key; no user identity is sent. `app(namespace:)` calls an installed app's endpoints; the namespace is install-time configuration, never a constant.

```swift
let created = await mos.callEndpoint(path: "notes", body: ["text": "Hello"])
let user = await mos.callEndpoint(pathSegments: ["users", userID], method: .get)   // each segment encoded whole: "a/b" → a%2Fb

let orders = mos.app(namespace: installedNamespace)
if case .response(let response) = await orders.call(path: "orders/recent", method: .get),
   response.isSuccess { /* response.json, response.headers */ }
```

## Failure model: fail-open

- Nothing throws after construction. A failed decision comes back as a `DecisionResult` whose `failure.reason` is `requestFailed`, `timeout`, `invalidJSON`, `apiError`, `httpError`, `invalidResponse`, `rateLimited`, `unauthorized` or `notConfigured`, served from the cache when it can be.
- `decide`, `redeem` and `flush` complete even if the calling task is cancelled. A cancelled endpoint call returns `.failed` with `requestFailed`.
- Failure reasons, redemption actions, experience kinds, property types and decision sources can gain cases in a minor release, so end a `switch` over one with `@unknown default:`.
- `hasAccess` answers `offline.failOpen` when there is no decision.
- **No automatic retry** of `surface-decisions`: it consumes and has no idempotency key, so a retry risks double-consuming.
- Redirects are never followed: a 3xx comes back as the response, so the key, a JWT and a request body only ever go to the API host.

## Logging & observability

The SDK **never prints on its own.** `onLog` receives every `LogEvent` (`level`, `code`, `message`, `context`) with stable codes, for example `decision:success`, `decision:fallback`, `metering:queued` and `transport:degraded`. Pipe events to your own logger, or pass the bundled `consoleLogger` while debugging. Every request carries a deliberate `User-Agent` and an `X-MOS-Mobile-Version` header.

## Privacy

The package ships a privacy manifest (`PrivacyInfo.xcprivacy`). It declares two data types, both linked to the user, used for app functionality only and never for tracking:

| Data type | Why it is collected |
| --- | --- |
| User ID | The anonymous identifier the server mints and the SDK keeps in the Keychain, and the subject of the host's JWT when the host passes a token. |
| Product interaction | The resource ids sent with decisions and deferred counter updates. |

The SDK reads no advertising identifier and no location. Everything is sent over HTTPS to the MonetizationOS API.

## Known limitations

- **Soft-gating, not enforcement.** Decisions and metering run in the app, so a modified client can skip them. Hard enforcement stays server-side.
- **No store purchase flow.** The SDK shows store prices through your `PriceProvider` and redeems offer tokens; the purchase itself is your StoreKit code.
- **Cache key.** `cacheFirst` and the exact cache entry match on surface, identity, resource id and components only. `properties`, `resource.meta` and `extra` are not part of the key, so a call that differs only in those gets the same entry.
- **Concurrent first decisions.** On a fresh install, decisions made before the first one returns each ask the server to mint an anonymous id. The SDK keeps the first id that comes back; meter counts made under the others do not follow the reader.
- **Counter updates can repeat.** A queued counter update whose request timed out stays queued and is sent again, so a meter without unique resources can count that read twice.
- **Linking is your workflow's job.** `previousAnonymousIdentifier` reaches the workflow in `context.properties`. The server does not link identities by itself; the workflow does, with `utils.identity.link`.
- **Anonymous history after sign-out.** After a sign-out the device goes back to its anonymous id, so the next account to sign in is offered the same anonymous history, even if an earlier account linked it. Call `reset()` after sign-out to start a new anonymous visitor instead.

## Contributing

Repository layout, tests, CI and releasing: see [CONTRIBUTING.md](./CONTRIBUTING.md). Report vulnerabilities privately, as described in [SECURITY.md](./SECURITY.md).

## License

MIT
