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
  # Boots through the machine-wide simulator gate, which queues for a slot; xcodebuild would boot it unmetered.
  sim boot "$udid" || case $? in
    75) fail "no simulator slot free for $udid after the wait; rerun later" ;;
    *) fail "sim boot $udid failed" ;;
  esac
  exec lease -- xcodebuild test -project "$project" -scheme PlaybackDeviceTests \
    -derivedDataPath "$derived" -destination "platform=iOS Simulator,id=$udid" \
    -parallel-testing-enabled NO -collect-test-diagnostics never "$@"
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

# The phone is shared with other repos' sessions, which lease it by name ("Elise's iPhone" is
# iphone-elise); hold that lease for the whole run, build included, so nobody installs mid-suite.
if [ -z "${DEVICE_TEST_PHONE_HELD:-}" ]; then
  xcrun devicectl list devices --quiet --json-output "$scratch/devices.json" >/dev/null
  phone="$(json "$scratch/devices.json" "import re; n = next(x['deviceProperties']['name'] for x in d['result']['devices']
    if x['hardwareProperties']['udid'] == '$udid'); n = re.sub(r\"['’]s iphone\$\", '', n.lower()); print('iphone-' + re.sub(r'[^a-z0-9]+', '-', n).strip('-'))")"
  rm -rf "$scratch"
  DEVICE_TEST_PHONE_HELD=1 exec lease --class "$phone" -- "$PWD/scripts/device-test.sh" "$udid" "$@"
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

team="$(scripts/lib/device-team.sh)" || fail "no signing team"

build=(-project "$project" -scheme PlaybackDeviceTests -derivedDataPath "$derived" -destination "id=$udid"
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration "DEVELOPMENT_TEAM=$team")
# With no Apple ID in Xcode, an App Store Connect API key lets xcodebuild register the phone and mint profiles.
if [ -n "${ASC_API_KEY_PATH:-}" ]; then
  build+=(-authenticationKeyPath "$ASC_API_KEY_PATH" -authenticationKeyID "${ASC_KEY_ID:?}"
    -authenticationKeyIssuerID "${ASC_ISSUER_ID:?}")
fi
# Without LEASE_HELD the build queues for a build slot instead of riding on the phone's lease.
env -u LEASE_HELD lease -- xcodebuild build-for-testing "${build[@]}" -quiet
xcrun devicectl device install app --device "$udid" --quiet "$derived/Build/Products/Debug-iphoneos/Interruptor.app"
check_unlocked
# xcodebuild hands TEST_RUNNER_ variables to the tests without the prefix.
TEST_RUNNER_DEVICE_INTERRUPTOR=1 xcodebuild test-without-building "${build[@]}" \
  -parallel-testing-enabled NO -collect-test-diagnostics never "$@"
