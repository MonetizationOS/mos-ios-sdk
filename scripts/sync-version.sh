#!/bin/sh
# Copies the version `changeset version` wrote to package.json into Version.swift.
set -e
cd "$(dirname "$0")/.."
version=$(sed -n 's/^ *"version": *"\([0-9][^"]*\)".*/\1/p' package.json | head -n 1)
[ -n "$version" ] || { echo "sync-version: no version in package.json" >&2; exit 1; }
sed -i.bak "s/^public let MOSVersion = \".*\"$/public let MOSVersion = \"$version\"/" Sources/MonetizationOS/Version.swift
rm Sources/MonetizationOS/Version.swift.bak
echo "$version"
