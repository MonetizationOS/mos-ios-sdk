#!/bin/sh
# Runs the Swift tests. Under Command Line Tools (no Xcode) SwiftPM does not find the
# Swift Testing macro plugin on its own, so pass the plugin path explicitly.
set -e
cd "$(dirname "$0")/.."
if [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
fi
exec swift test "$@"
