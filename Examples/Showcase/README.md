# MOS Showcase

An example app, one screen per SDK use case, plain placeholder content. Each screen is a single file with its MOS calls inline, so you can copy the pattern straight out of it. Every screen starts with a one-line explainer and ends with a **Last call** panel: the call made, `result.source`, and the raw response JSON.

- `fixtures/`: the responses fixture mode answers from. Its README is the fixture server's spec.
- `ios/`: SwiftUI, iOS 18+, Swift 6, XcodeGen. Screens in `Showcase/Screens/`, shared plumbing in `Showcase/Support/`.

## Screens

| Section | Screen | Shows |
| --- | --- | --- |
| Basics | Gate content | `decide(resource:)` on `article/1` (free) or `article/2` (premium), branch on `hasAccess(feature: "article", property: "enabled")` |
| | Metered access | Per-call `surface: "showcase-metered"`; each new `item/N` consumes the `items.views` meter, a repeat does not (`uniqueResources`); 3 free |
| | Feature switch | Boolean `ads.enabled` shows or hides an ad slot |
| | Surface properties | `decision.surfaceProperties["banner"]` (text, tone, cta) drawn natively, on surface `showcase-home` |
| Paywalls | Native paywall | `decision.experience("paywall")` is `.native`: copy and offer slots drawn natively in SwiftUI, `redeem(offerToken:)` on tap |
| | Web paywall | `decision.experience("webPaywall")` is `.web(html)` in `MOSWebPaywallView` with a fixed-price `PriceProvider`; `onRedemption` and `onClose` |
| | Redeem an offer | One offer per `RedemptionResult`: custom action, navigate, none, declined (and failed with Offline on), and what an app does with each |
| Identity | Sign in and out | `identify(userJWT:)`, its `IdentifyResult`, and the next decision carrying `previousAnonymousIdentifier`; `identify(userJWT: nil)` to sign out |
| Offline | Offline | An Offline switch (a transport that fails every request): `source` moving network, cache, fallback, unavailable; `failOpen`; queued counter updates; `flush()`; `clearCache()` |
| Apps | App endpoints | `mos.app(namespace:)`: GET, POST with a body, `.response` vs `.failed` |

**Home** lists the screens under three live rows: mode (Fixture, or Live and the host), the current identity, and where the last decision came from. **Settings** (gear icon): mode, public key, API base URL, endpoint namespace, and Reset identity (a new anonymous reader, cache and queue cleared). Saving a new mode, key or host rebuilds the MOS instance and resets the old one (identity, cache and queue). The SDK already keeps keys for different environments apart; the reset matters when the new key is for the same environment, as with a new host and the same key.

## Fixture mode

The default when no public key is configured. No key, no backend: a transport injected into `MOSConfig.transport` answers every request from `fixtures/` and keeps just enough state (meters per reader, signed in or not, claimed offers). The rest is the real SDK: identity, cache, metering queue, web paywall. Everything in the table above works in fixture mode.

## Live mode

Live mode talks to your own MonetizationOS org, set up as in the contract below. With a key prefilled as below, the app starts in Live mode; otherwise open Settings, choose Live, enter your org's `pk_` key and API base URL, and Save. To prefill them, create `ios/Config.local.xcconfig` (gitignored):

```
MOS_PUBLIC_KEY = pk_<env>_<id>_<secret>
MOS_API_BASE_URL = https:/$()/api.monetizationos.com
MOS_ENDPOINT_NAMESPACE = showcase
```

On Sign in and out, paste a JWT from your org's JWT integration.

## Run

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Use any iPhone simulator you have; `xcrun simctl list devices available` lists them.

```sh
cd Examples/Showcase/ios
xcodegen generate                      # project.yml → Showcase.xcodeproj (not committed)
open Showcase.xcodeproj                # or build from the command line:
xcodebuild -project Showcase.xcodeproj -scheme Showcase -destination 'platform=iOS Simulator,name=<your iPhone>' build
# UI tests: every screen in fixture mode. Screenshots as PNGs:
TEST_RUNNER_SHOWCASE_SHOTS=/tmp/showcase-shots xcodebuild -project Showcase.xcodeproj -scheme Showcase \
  -destination 'platform=iOS Simulator,name=<your iPhone>' test
```

The UI tests launch with `SHOWCASE_RESET=1`: fixture mode and a new anonymous reader.

## Live-org contract

What an org needs for every screen to work live; fixture mode needs none of it. The Android SDK's Showcase uses the same names.

**Surfaces.** `config.surface` is `showcase`; two screens pass another surface per call.

| Surface | Resource ids | Features | Surface properties |
| --- | --- | --- | --- |
| `showcase` | `article/1` (`meta.tier: free`), `article/2` (`meta.tier: premium`), `feed`, `paywall/native`, `paywall/web`, `offers/redeem` | `article.enabled` (boolean), `ads.enabled` (boolean) | `paywall`, `webPaywall`, `offers` |
| `showcase-metered` | `item/1` to `item/5`, `offline/1`, `offline/2` | `items.views` (meterable, unique resources, 3 per period) for `item/*`; `offline.views` (meterable, unique resources, a high limit) for `offline/*` | none |
| `showcase-home` | `home` | none | `banner` |

Every decision also carries `properties.platform` (`ios`; `android` from the Android Showcase).

**Workflow behaviour** (the fixtures do the same):

- `article.enabled`: true for `tier: free`; for `tier: premium` and on `paywall/*`, true only for a subscriber.
- `ads.enabled`: false for a signed-in reader or a subscriber, true otherwise.
- Without access, `paywall/native` returns `paywall` and `paywall/web` returns `webPaywall`; with access, neither key.
- `banner`: `{ "text": String, "tone": "info" | "success" | "warning", "cta": String? }`, e.g. a sign-in prompt for anonymous readers and a welcome back for signed-in ones.
- For a signed-in reader, the `showcase` workflow links `context.properties.previousAnonymousIdentifier` to the account (`utils.identity.link`), so what the reader had before signing in follows them.

**Experiences.** One property key per experience slot.

| Key | Kind | Content |
| --- | --- | --- |
| `paywall` | app experience, `resolveAsJson` | `{ headline, body, benefits: [String] }` plus `mos-offer-slots` with the monthly and annual offers |
| `webPaywall` | html experience, `resolveAsWebContent` | Plan links `<a href="mos://redeem?token={{mos-offer-token}}">`, prices in `data-mos-product="{{storeProductId}}"` (and `data-mos-price="display-period"`), optional `<a href="mos://close">`. `fixtures/html/web-paywall.html` is a working example. |
| `offers` | app experience, `resolveAsJson` | `{ title }` plus `mos-offer-slots` with one offer per redemption outcome, in this order: monthly, navigate, free week, expired |

**Offers.** Presentation keys the apps read: `title`, `subtitle`, `badge` (optional), `storeProductId`, `fallbackPrice`.

| Offer | `storeProductId` | Redemption answers |
| --- | --- | --- |
| Monthly | `com.monetizationos.showcase.monthly` | `custom:storekit` with `properties.storeProductId` |
| Annual (badge "Best value") | `com.monetizationos.showcase.annual` | `custom:storekit` with `properties.storeProductId` |
| Open a welcome page | none | `navigate` to a URL |
| Claim a free week | none | `none` the first time, declined after that |
| An expired offer | none | declined |

**Identity.** A JWT integration with claim key `sub`, the SDK's default `claimKey`. Paste one of its tokens on the Sign in screen.

**App endpoints.** An installed app in namespace `showcase` (Settings changes it) with `GET profile` and `POST notes` (any 2xx). An org without that app can use its own endpoints instead: create them in the default namespace and set the endpoint namespace to `default`.
