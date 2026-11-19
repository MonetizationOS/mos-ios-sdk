# Contributing

The Swift package lives in `Sources/` with its tests in `Tests/MOSTests`. The Android SDK, [MonetizationOS/mos-android-sdk](https://github.com/MonetizationOS/mos-android-sdk), implements the same behaviour: a behaviour change lands in both, with tests in both. `fixtures/` holds conformance fixtures that both SDKs' test suites load; its README lists what each file must produce. `fixtures/` and `Sources/MonetizationOS/WebPaywall/shared/` are copies of the Android SDK's: change them in both repositories, and `scripts/check-shared.sh` checks they match.

Open an issue before a large change or a new public API. Keep a pull request to one change, with tests, and CI green. Tests use clearly fake keys and ids (`pk_test_...`, `example.com`); never commit a real key, token or customer data.

## Repository layout

- `Package.swift`, `Sources/MonetizationOS`, `Sources/MonetizationOSUI`, `Tests/MOSTests`: the Swift package (iOS 18+, macOS 15+).
- `Sources/MonetizationOS/WebPaywall/shared/`: the web paywall's document and scripts. The Android SDK ships the same files.
- `fixtures/`: conformance fixtures the tests load, the same set the Android SDK's tests load.
- `Examples/Showcase`: an example SwiftUI app, one screen per use case.

## Scripts

| Command | What it does |
| --- | --- |
| `scripts/swift-test.sh` | Swift tests on macOS. Works with Command Line Tools alone; extra arguments go to `swift test`. |
| `scripts/ios-test.sh` | Builds every product for a generic iOS device, then runs the suite on an iOS simulator through xcodebuild. Needs Xcode, and picks `/Applications/Xcode.app` itself when xcode-select points at Command Line Tools. Uses a plain iPhone from the newest iOS runtime; `MOS_SIMULATOR` picks another by name. Extra arguments go to xcodebuild. |
| `scripts/check-version.sh [tag]` | Fails unless `package.json` and `Version.swift` agree and `CHANGELOG.md` has a section for that version. |
| `scripts/check-changeset.sh [base]` | Fails unless a branch that changes `Sources/` adds a changeset. |
| `scripts/check-api.sh [base]` | Fails when the public API of `MonetizationOS` or `MonetizationOSUI` breaks against the latest `v*` tag, unless the branch adds a `minor` or `major` changeset (compared with `origin/<base>`, `main` by default). Passes until the first tag. |
| `scripts/check-shared.sh [path]` | Fails unless `fixtures/` and the web paywall files match the Android SDK's, from a local checkout at `path` or a fresh clone. |

## Showcase

`Examples/Showcase` is a SwiftUI app that runs on bundled fixtures with no account. It needs XcodeGen (`brew install xcodegen`); its README says how to build, run and UI-test it. A new SDK use case usually gets a screen, here and in the Android SDK's Showcase. CI builds it.

## Versioning & release

Every user-visible change needs a changeset: run `pnpm changeset` (after `pnpm install`), or write the file by hand; [`.changeset/README.md`](.changeset/README.md) shows the format. A change that lands in both SDKs gets the same wording in each. A pull request that changes `Sources/` fails the Changeset check without one; label it `no-changelog` when nothing user-visible changed.

On `main`, the Release workflow opens or updates a "chore: release mos-ios-sdk" pull request that bumps `package.json` and `Version.swift` and writes `CHANGELOG.md` from the pending changesets, then runs CI on it. Merging it runs the tests, then makes the tag (`v0.9.1`) and a GitHub release from the CHANGELOG section. Swift Package Manager installs straight from the tag.

The workflow runs only on `main`. It releases whenever the version in `package.json` has no `v<version>` tag and an earlier `v*` tag exists, whether or not changesets are pending, so a release that a cancelled or failed run missed goes out on the next push to `main`. The first release has no earlier tag: run the Release workflow by hand on `main`.

To redo a release, for example when its tag is on the wrong commit, delete the release and its tag with `gh release delete v<version> --cleanup-tag`, then run the Release workflow by hand on `main`. Swift Package Manager pins the commit a tag resolved to, so redo only a release nobody can have installed yet; otherwise release a patch.

## CI

CI runs on every pull request. The release pull request is opened with the workflow's `GITHUB_TOKEN`, which starts no workflows, so the Release workflow dispatches CI on its branch (`changeset-release/main`) instead. CI runs:

- The package builds and its unit tests run on macOS (Xcode 26), then the same suite on an iOS simulator (Xcode 27), including a real `WKWebView` paywall. The simulator run is serial: in parallel the runner starves the wall-clock timeout tests.
- The Showcase app builds.
- `scripts/check-version.sh`, and `scripts/check-shared.sh`, which compares the fixtures and web paywall files with the Android SDK's.
- On pull requests only, the `api` job runs `scripts/check-api.sh`: a public API break since the latest release tag needs a `minor` changeset.

The tests use fixtures and fake transports. The Showcase UI tests are not part of CI, and nothing in CI uses a physical device or a live MonetizationOS environment.
