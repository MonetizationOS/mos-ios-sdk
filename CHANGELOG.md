# mos-ios-sdk

## 0.9.0

The first public release.

What it does
- Decisions: `decide` posts a surface decision with the public key and returns the typed `features` (boolean, number, string and meterable properties) and the open surface JSON your workflow produces, with `hasAccess` for gating. `components` runs only the named components of the surface.
- Identity: a server-minted anonymous id kept in the Keychain (or a key-value `IdentityStore` of your own), `identify(userJWT:)` or a `jwtProvider` for signed-in users, with `claimKey` naming the JWT claim your integration identifies users by (`sub` by default), and an anonymous-to-signed-in hand-off: decisions after a sign-in carry `properties.previousAnonymousIdentifier`, until one is answered for the signed-in user, so a workflow can link the two. An anonymous answer to a signed-in request is returned but not cached or metered.
- Offline: decisions are cached per surface, identity, resource and component selection, until the TTL or the earliest offer token in them expires (web paywall markup included), and served when the network fails (`result.source` says which). The default stores are kept per environment of the public key, so a staging and a production key never share an anonymous id, cache or queue. When there is no decision at all, `hasAccess` answers the `failOpen` setting. Nothing throws after construction.
- Metering: a decision served from the cache queues counter updates for the meters it consumed; `flush()` sends them, and a successful network decision flushes in the background when anything is queued. Offline, meters keep counting down from the last network decision, and `enforceMeters` turns access off once they are used up.
- Offers: `redeem(offerToken:)` returns the redemption action (`navigate`, `custom` for a `custom` or `custom:*` type, or `noAction`) or a declined or failed outcome. A redeemed offer clears the decision cache.
- App endpoints: `callEndpoint` and `mos.app(namespace:)` call the endpoints of an installed app.
- Transport: after a timeout, decisions and counter updates use `min(requestTimeout, 2 s)` for ten minutes or until any response; redemptions and endpoint calls always get the full `requestTimeout`. Requests never follow redirects, so the key and a JWT only ever go to the API host. An `HTTPRequest` prints and dumps without its body or identity header values. Durations of any size are accepted: a huge ttl or `maxAge` means forever.
- Paywalls: `Experience` tells a native experience (app JSON plus typed offers) from a web one (server-rendered HTML). `MOSWebPaywallView` in `MonetizationOSUI` (WebKit) shows a web one, fills store prices through a `PriceProvider`, reports redemptions and close, and calls `onClose` when the page's content process ends twice within 30 seconds.
- Privacy: a privacy manifest.

Platforms
- Swift 6 package: iOS 18+ and macOS 15+. Products: `MonetizationOS` and `MonetizationOSUI`.

Distribution
- Swift Package Manager installs from the version tag.
