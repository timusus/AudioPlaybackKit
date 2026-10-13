#!/usr/bin/env bash
#
# Runs Tests/PlaybackDeviceTests, the player with the real session, renderer and Now Playing centres,
# through a generated host app (an iPhone cannot run a package's test bundle).
#
#   scripts/device-test.sh [UDID] [xcodebuild args...]          a paired iPhone; default the first
#   scripts/device-test.sh --simulator UDID [xcodebuild args...]
#
# On a phone it also installs the Interruptor app, which RealCallTests drives for a real CallKit
# call. The signing team is DEVELOPMENT_TEAM, else read from the keychain; it is never committed.
# ASC_API_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID (an App Store Connect key) sign when Xcode has no Apple ID.
set -euo pipefail

cd "$(dirname "$0")/.."
spec=Tests/PlaybackDeviceTests/project.yml
project=Tests/PlaybackDeviceTests/PlaybackDeviceTests.xcodeproj
derived=.build/device-tests/dd
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

fail() { echo "device-test: $*" >&2; exit 1; }

command -v xcodegen >/dev/null || fail "needs xcodegen (brew install xcodegen)"
xcodegen generate --quiet --spec "$spec"

if [ "${1:-}" = "--simulator" ]; then
  [ -n "${2:-}" ] || fail "--simulator needs a UDID from: xcrun simctl list devices available"
  udid="$2"; shift 2
  exec lease -- xcodebuild test -project "$project" -scheme PlaybackDeviceTests \
    -derivedDataPath "$derived" -destination "platform=iOS Simulator,id=$udid" "$@"
fi

json() { python3 -I -c "import json, sys; d = json.load(open(sys.argv[1])); $2" "$1"; }

if [ -n "${1:-}" ] && [ "${1#-}" = "$1" ]; then
  udid="$1"; shift
else
  xcrun devicectl list devices --quiet --json-output "$scratch/devices.json" >/dev/null
  udid="$(json "$scratch/devices.json" "print(next((x['hardwareProperties']['udid'] for x in d['result']['devices']
    if x['hardwareProperties'].get('reality') == 'physical' and x['hardwareProperties'].get('deviceType') == 'iPhone'
    and x['connectionProperties'].get('pairingState') == 'paired'), ''))")"
  [ -n "$udid" ] || fail "no paired iPhone; pair one in Xcode or pass a UDID"
fi

# A locked phone cannot launch the host, and xcodebuild waits on it rather than failing.
# Checked again after the build, which can outlast the auto-lock; the host keeps it awake from then on.
check_unlocked() {
  xcrun devicectl device info lockState --device "$udid" --quiet --json-output "$scratch/lock.json" >/dev/null \
    || fail "cannot reach $udid; is it connected and trusted?"
  [ "$(json "$scratch/lock.json" "print(d['result']['passcodeRequired'])")" = "False" ] \
    || fail "$udid is locked; unlock it and rerun"
}
check_unlocked

# Each Apple certificate's OU is its team. More than one team: the Simplecity one, else ask.
team="${DEVELOPMENT_TEAM:-}"
if [ -z "$team" ]; then
  security find-certificate -a -c "Apple D" -p | awk -v dir="$scratch" '/BEGIN/ { n++ } { print > (dir "/cert" n ".pem") }'
  teams="$(for pem in "$scratch"/cert*.pem; do
    openssl x509 -noout -subject -in "$pem" | sed -n 's/.*OU *= *\([A-Z0-9]*\), *O *= *\([^,]*\).*/\1 \2/p'
  done | sort -u)"
  team="$(echo "$teams" | awk '/Simplecity/ { print $1; exit }')"
  [ -n "$team" ] || [ "$(echo "$teams" | wc -l)" -ne 1 ] || team="$(echo "$teams" | awk '{ print $1 }')"
  [ -n "$team" ] || fail "cannot pick a team from the keychain; set DEVELOPMENT_TEAM. Found: $teams"
fi

build=(-project "$project" -scheme PlaybackDeviceTests -derivedDataPath "$derived" -destination "id=$udid"
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration "DEVELOPMENT_TEAM=$team")
# With no Apple ID in Xcode, an App Store Connect API key lets xcodebuild register the phone and mint profiles.
if [ -n "${ASC_API_KEY_PATH:-}" ]; then
  build+=(-authenticationKeyPath "$ASC_API_KEY_PATH" -authenticationKeyID "${ASC_KEY_ID:?}"
    -authenticationKeyIssuerID "${ASC_ISSUER_ID:?}")
fi
lease -- xcodebuild build-for-testing "${build[@]}" -quiet
lease --class device -- xcrun devicectl device install app --device "$udid" --quiet "$derived/Build/Products/Debug-iphoneos/Interruptor.app"
check_unlocked
# xcodebuild hands TEST_RUNNER_ variables to the tests without the prefix.
TEST_RUNNER_DEVICE_INTERRUPTOR=1 lease --class device -- xcodebuild test-without-building "${build[@]}" "$@"
