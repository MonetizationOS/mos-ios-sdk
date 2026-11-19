#!/bin/sh
# Builds every product (MonetizationOS, MonetizationOSUI) for a generic iOS device through the
# MonetizationOS-Package scheme, then runs the test suite on a simulator: MOS_SIMULATOR, else a plain
# iPhone from the newest iOS runtime. When xcode-select points at Command Line Tools, drives
# /Applications/Xcode.app directly so no sudo xcode-select is needed.
set -e
cd "$(dirname "$0")/.."
if [ -z "$DEVELOPER_DIR" ] && [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# Prints "<udid> <name>": MOS_SIMULATOR by name if set, else a plain iPhone from the newest runtime that has one.
PICK=$(xcrun simctl list devices available -j | python3 -c '
import json, os, re, sys
devices = json.load(sys.stdin)["devices"]
# Runtime ids are like ...SimRuntime.iOS-27-1, sometimes with a suffix (iOS-26-2-iPhone19): sort on the leading numbers.
version = lambda k: [int(x) for x in re.match(r"\d+(?:-\d+)*", k.rsplit(".iOS-", 1)[1]).group(0).split("-")]
want = os.environ.get("MOS_SIMULATOR")
for runtime in sorted((k for k in devices if re.search(r"\.iOS-\d", k)), key=version, reverse=True):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone") and (not want or d["name"] == want)]
    if phones:
        pick = next((d for d in phones if re.fullmatch(r"iPhone \d+", d["name"])), phones[0])
        print(pick["udid"], pick["name"])
        break
')
[ -n "$PICK" ] || { echo "No iPhone simulator found${MOS_SIMULATOR:+ named $MOS_SIMULATOR}" >&2; exit 1; }
UDID=${PICK%% *}
echo "Simulator: ${PICK#* } ($UDID)"
xcodebuild build -scheme MonetizationOS-Package -destination 'generic/platform=iOS' -quiet
# A simulator still finishing its boot starves the timing tests, so boot it and wait first.
xcrun simctl bootstatus "$UDID" -b > /dev/null
exec xcodebuild test -scheme MonetizationOS-Package -destination "id=$UDID" "$@"
