#!/bin/sh
# Fails unless the conformance fixtures and the web paywall's document and scripts match the Android SDK's
# copies byte for byte. Pass a local mos-android-sdk checkout, or let it clone the default branch of
# https://github.com/MonetizationOS/mos-android-sdk (SHARED_REPO_TOKEN while it is private).
# Change these files in both repositories in the same release.
set -e
cd "$(dirname "$0")/.."
other="$1"
if [ -z "$other" ]; then
  other=$(mktemp -d)
  trap 'rm -rf "$other"' EXIT
  # A private repository needs a token with read access in SHARED_REPO_TOKEN. Without one the check is
  # skipped with a warning rather than failed.
  url="https://${SHARED_REPO_TOKEN:+x-access-token:$SHARED_REPO_TOKEN@}github.com/MonetizationOS/mos-android-sdk"
  if ! git clone --quiet --depth 1 "$url" "$other" 2>/dev/null; then
    if [ -z "$SHARED_REPO_TOKEN" ]; then
      echo "::warning::check-shared skipped: cannot read MonetizationOS/mos-android-sdk; set the SHARED_REPO_TOKEN secret"
      exit 0
    fi
    echo "check-shared: cannot clone MonetizationOS/mos-android-sdk with SHARED_REPO_TOKEN" >&2
    exit 1
  fi
fi
status=0
check() {
  if [ ! -d "$other/$2" ]; then
    echo "check-shared: $2 not found in the Android SDK" >&2
    status=1
  elif ! diff -r "$1" "$other/$2"; then
    echo "check-shared: $1 differs from the Android SDK's $2" >&2
    status=1
  fi
}
check fixtures fixtures
check Sources/MonetizationOS/WebPaywall/shared mos-core/src/main/resources/com/monetizationos/sdk/webpaywall
[ "$status" = 0 ] && echo "check-shared: fixtures and web paywall match the Android SDK"
exit "$status"
