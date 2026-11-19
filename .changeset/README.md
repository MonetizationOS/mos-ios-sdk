# Changesets

Every user-visible change needs a changeset: a small markdown file in this folder that says how to bump the version and what changed. [Changesets](https://github.com/changesets/changesets) turns them into `CHANGELOG.md` entries.

## Workflow in this repo

1. Run `pnpm changeset` and describe the change, or write the file by hand:

   ```md
   ---
   "mos-ios-sdk": patch
   ---

   `decide` no longer ...
   ```

   Before 1.0 a breaking change is `minor`; `major` would release 1.0.0. So while the version is 0.x a public API break needs a `minor` changeset, and the pull request's `api` check (`scripts/check-api.sh`) fails without one.
2. Commit the file in `.changeset/` with the code change. A change that lands in both SDKs gets the same wording in the Android SDK's changeset.
3. When merged to `main`, the **Release** workflow opens (or updates) a "chore: release mos-ios-sdk" PR that bumps `package.json` and `Version.swift`, updates `CHANGELOG.md`, and consumes the changeset files.
4. Merging that PR runs the tests, then makes the tag (`v0.9.1`) and a GitHub release from the CHANGELOG section. Swift Package Manager installs straight from the tag.

A pull request that changes `Sources/` fails the **Changeset** check without one. Label it `no-changelog` when it has nothing user-visible.
