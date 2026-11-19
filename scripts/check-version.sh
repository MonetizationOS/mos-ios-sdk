#!/bin/sh
# Fails unless package.json and Version.swift agree and CHANGELOG.md has a section for that version.
# Pass the release tag (v0.9.0) to also require the tag to be that version.
set -e
cd "$(dirname "$0")/.."
version=$(sed -n 's/^public let MOSVersion = "\(.*\)"$/\1/p' Sources/MonetizationOS/Version.swift)
package=$(sed -n 's/^ *"version": *"\([0-9][^"]*\)".*/\1/p' package.json | head -n 1)
fail() { echo "check-version: $*" >&2; exit 1; }
[ -n "$version" ] || fail "no MOSVersion in Version.swift"
[ "$package" = "$version" ] || fail "package.json version $package != MOSVersion $version"
grep -qx "## $version" CHANGELOG.md || fail "CHANGELOG.md has no '## $version' section"
[ -z "$1" ] || [ "$1" = "v$version" ] || fail "tag $1 != v$version"
echo "$version"
