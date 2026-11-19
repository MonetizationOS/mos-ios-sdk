#!/bin/sh
# Prints version=<x> for $GITHUB_OUTPUT when the Release workflow should release package.json's version: tag v<x> does
# not exist yet, and the run was started by hand or an earlier v* tag exists. The first release is by hand; after it, a
# version a cancelled or failed run missed goes out on the next push to main.
# Usage: release-version.sh <event name>
set -e
cd "$(dirname "$0")/.."
version=$(sed -n 's/^ *"version": *"\([0-9][^"]*\)".*/\1/p' package.json | head -n 1)
[ -n "$version" ] || { echo "release-version: no version in package.json" >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/v$version" > /dev/null; then exit 0; fi
if [ "$1" != workflow_dispatch ] && [ -z "$(git tag --list 'v*')" ]; then exit 0; fi
echo "version=$version"
