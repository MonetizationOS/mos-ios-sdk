# Showcase fixtures

The responses the Showcase app answers from in fixture mode. The app injects an `HTTPTransport` that reads this folder, so every request still goes through the SDK's real code path. The implementation, `ios/Showcase/Support/FixtureTransport.swift`, follows the rules listed here.

Fixture mode uses the public key `pk_test_showcase_fixtures` (environment `test_showcase`) and the API base URL `https://fixtures.showcase.invalid`. Neither is ever contacted.

## Layout

| Path | Answers |
| --- | --- |
| `routes.json` | Which file answers which request. Read once at start. |
| `offers.json` | Every offer the decisions reference, by id, with fixture-only redemption fields. |
| `decisions/` | `POST /api/v1/surface-decisions`, one file per screen and scenario. |
| `html/` | Web paywall markup, inlined into decisions (see `contentFile`). |
| `redemptions/` | `POST /api/v1/offer-redemptions`. |
| `counter-updates/` | `POST /api/v1/counter-updates`. |
| `endpoints/` | App endpoint calls. |
| `errors/` | Anything without a route. |

Two file shapes:

- **Body files** (`decisions/`, `redemptions/`, `counter-updates/`): the JSON body of a 200 response.
- **Envelope files** (`endpoints/`, `errors/`): `{ "status": <int>, "headers": { ... }, "body": <any JSON> }`. Respond with that status, `Content-Type: application/json` plus those headers, and `body` serialised.

## Loading a file

Every file is read as text and goes through the same three steps, in order:

1. **Placeholders** (plain text replacement, before parsing):
   - `"{{requestBody}}"`, quotes included: the request body as raw JSON (`null` when empty). Endpoints only.
   - `{{eventId}}`: one new lowercase UUID per file load.
   - `{{<key>}}` (redemptions): each string in the redeemed offer's `fixtureRedemptionValues`, which stand in for its redemption values in MOS.
   - `{{path}}` (errors): the unmatched path, or `"<surface> <resource id>"` for an unmatched decision.
   - `{{token:<offer id>}}`: a fresh offer token for that offer (below). Used inside html.
2. **Parse** as JSON.
3. **Expand**, recursively through every object and array:
   - A `mos-offer-slots` array whose items are strings: each string is an offer id, replaced by `{ "type": "single", "offer": { "id", "redemptionSchema", "presentation", "token" } }` from `offers.json` (only those four keys; the `fixture*` keys never leave the server).
   - An object `{ "type": "html", "contentFile": "<path>" }`: `contentFile` is removed and `content` set to that file's text after step 1's placeholders.

### Offer tokens

Shaped like the server's ES256 JWT; the SDK reads the payload and never checks the signature. `base64url(header) + "." + base64url(payload) + "." + base64url(64 random bytes)`, no padding:

- header `{"alg":"ES256","typ":"JWT"}`
- payload `{"id": <offer id>, "presentation": <presentation>, "redemptionSchema": <schema or null>, "expirationMsUtc": <now + 1 hour, ms>}`

## The caller

Decisions, redemptions and counter updates carry `identity` in the body; endpoint calls carry none.

| Request has | Caller key | Decision `identity` |
| --- | --- | --- |
| `identity.userJwt` | `jwt:<sub>`; `sub` from the token's payload, `user` when unreadable. Any token is accepted. | `{ identifier: <sub>, isAuthenticated: true, authType: "jwt", jwtClaims: <payload> }` |
| `identity.anonymousIdentifier` | `anon:<id>` | `{ identifier: <id>, isAuthenticated: false, authType: "anonymous", jwtClaims: {} }` |
| `identity.createAnonymousIdentifier` (or nothing) | mint `mos-anon-v1-fixture-<uuid>` | as anonymous, with the minted id |

`userJwt` wins when both are present (`createAnonymousIdentifierFallback` is ignored).

## State

Kept in memory for the life of the transport (the app process, or until Settings rebuilds MOS). Nothing is persisted.

| State | Keyed by | Changed by |
| --- | --- | --- |
| Meters: a set of resource ids | `<caller key>|<counterId>` | decisions with a meterable property; counter updates |
| Claimed offers | `<caller key>|<offer id>` | redeeming an offer that has `fixtureRepeatRedemption` |

## Routes

Wait about 150 ms before answering any request, so loading states are visible. Paths are compared decoded.

### `POST /api/v1/surface-decisions`

1. Resolve the caller.
2. Find the first entry in `routes.decisions` whose `surface` equals `surfaceSlug` and whose `resource` equals `resource.id`; a `resource` ending in `*` matches by prefix. No match: the `notFound` envelope (404).
3. Pick the file: `authenticatedFile` if the caller is a JWT and the route has one, else `file`.
4. Load it, set `identity` to the caller's decision identity, then fill each meter (below).

**Meters.** Every feature property with `"type": "meterable"` is a unique-resource meter. With `total = totalUnits`, `used` = the set for `<caller key>|<counterId>` and `id` = `resource.id`:

| Case | `hasAccess` | `consumedInRequest` | `resourceIdUsed` | `consumedUnitsInRequest` | `excessUnitsInRequest` |
| --- | --- | --- | --- | --- | --- |
| `id` already in `used` | true | false | true | 0 | 0 |
| else `used.count < total`: add `id` | true | true | false | 1 | 0 |
| else | false | false | false | 0 | 1 |

Then `isFallback: false`, `consumedUnits: used.count`, `remainingUnits: max(total - used.count, 0)`. Keep `counterId`, `totalUnits`, `uniqueResources`, `periodStart` from the file.

| Surface | Resource | File (authenticated) | Screen |
| --- | --- | --- | --- |
| `showcase` | `article/1` | `gate-content.free` | Gate content, Sign in |
| `showcase` | `article/2` | `gate-content.premium-locked` | Gate content |
| `showcase-metered` | `item/*` | `metered-access` (meter `items-views`, 3) | Metered access |
| `showcase-metered` | `offline/*` | `offline` (meter `offline-views`, 50) | Offline |
| `showcase` | `feed` | `feature-switch.ads-on` (authenticated: `feature-switch.ads-off`) | Feature switch |
| `showcase-home` | `home` | `surface-properties.anonymous` (authenticated: `surface-properties.signed-in`) | Surface properties |
| `showcase` | `paywall/native` | `native-paywall` | Native paywall |
| `showcase` | `paywall/web` | `web-paywall` | Web paywall |
| `showcase` | `offers/redeem` | `redeem-offer` | Redeem an offer |

### `POST /api/v1/offer-redemptions`

Read the offer id from `offerToken`'s payload (`id`). An unreadable token or unknown offer: 400 `{"status":"error","statusCode":400,"message":"Invalid offer token"}`. Otherwise answer `fixtureRedemption`, except: an offer with `fixtureRepeatRedemption` is claimed by the caller on its first redemption, and every later redemption by the same caller answers `fixtureRepeatRedemption`.

| Offer | First answer | Outcome in the SDK |
| --- | --- | --- |
| `offer-monthly`, `offer-annual` | `custom-storekit` | `redeemed(custom("custom:storekit", { storeProductId }))` |
| `offer-navigate` | `navigate` | `redeemed(navigate(https://example.com/welcome))` |
| `offer-free-week` | `none`; again: `declined.already-claimed` (409) | `redeemed(none)`, then `declined` |
| `offer-expired` | `declined.expired` (410) | `declined` |

`failed` needs no fixture: turn Offline on.

### `POST /api/v1/counter-updates`

Add `resourceId` to the set for `<caller key>|<counterId>`, then answer `counterUpdate` (`{"status":"success"}`).

### `/api/v1/envs/{env}/namespaces/{namespace}/endpoints/{path}` and `/api/v1/envs/{env}/endpoints/{path}`

`{path}` is everything after `endpoints/`, joined with `/`.

The first entry in `routes.endpoints` with the same `method` and `path`. Any namespace matches. No match: the `endpointNotFound` envelope (404).

| Call | File |
| --- | --- |
| `GET profile` | `profile`: 200 |
| `POST notes` | `notes.created`: 201, `received` echoes the request body |

### Anything else

The `notFound` envelope: 404 `{"status":"error","statusCode":404,"message":"No fixture for <path>"}`.
