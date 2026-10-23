#!/usr/bin/env bash
#
# Measures the player's energy use on Elise's iPhone at one commit, to compare commits:
#
#   scripts/device-energy.sh <commit-or-ref> <out-dir>
#
# Builds the device host (Tests/PlaybackDeviceTests, this checkout's copy) against the Sources of <ref> in a
# temporary worktree, runs its energy scenario (PLAYBACK_ENERGY=1: playing 1x, 1.5x, paused, idle, then a bare
# AVAudioPlayer, 60 s each) under xctrace, and writes <out-dir>/summary.md with CPU % and wakeups/s per state.
# The phone is held under its lease for the whole run, and must be unlocked.
set -euo pipefail

udid=00008110-001A703102C1401E
bundle=com.simplecityapps.playbackdevicetests

cd "$(dirname "$0")/.."
root="$PWD"
fail() { echo "device-energy: $*" >&2; exit 1; }

[ $# -eq 2 ] || fail "usage: scripts/device-energy.sh <commit-or-ref> <out-dir>"
sha="$(git rev-parse --verify "$1^{commit}")" || fail "unknown ref $1"
mkdir -p "$2"
out="$(cd "$2" && pwd)"

if [ -z "${DEVICE_ENERGY_PHONE_HELD:-}" ]; then
  DEVICE_ENERGY_PHONE_HELD=1 exec lease --class iphone-elise -- "$root/scripts/device-energy.sh" "$sha" "$out"
fi

work="$(mktemp -d)"
wt="$work/tree"
cleanup() { git -C "$root" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

git worktree add --detach --quiet "$wt" "$sha"
# The scenario code is this checkout's, so an older ref builds the same host against its own Sources.
rm -rf "$wt/Tests/PlaybackDeviceTests"
cp -R "$root/Tests/PlaybackDeviceTests" "$wt/Tests/PlaybackDeviceTests"
rm -rf "$wt/Tests/PlaybackDeviceTests/PlaybackDeviceTests.xcodeproj"

xcrun devicectl device info lockState --device "$udid" --quiet --json-output "$work/lock.json" >/dev/null \
  || fail "cannot reach $udid; is it connected and trusted?"
python3 -I -c "import json, sys; sys.exit(json.load(open(sys.argv[1]))['result']['passcodeRequired'])" "$work/lock.json" \
  || fail "$udid is locked; unlock it and rerun"

team="$("$root/scripts/lib/device-team.sh")"
spec="$wt/Tests/PlaybackDeviceTests/project.yml"
derived="$work/dd"
xcodegen generate --quiet --spec "$spec"
env -u LEASE_HELD lease -- xcodebuild build -project "$wt/Tests/PlaybackDeviceTests/PlaybackDeviceTests.xcodeproj" \
  -scheme PlaybackDeviceTests -derivedDataPath "$derived" -destination "id=$udid" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration "DEVELOPMENT_TEAM=$team" -quiet
xcrun devicectl device install app --device "$udid" --quiet "$derived/Build/Products/Debug-iphoneos/DeviceTestHost.app"

echo "$sha" > "$out/ref.txt"
# One recording: Activity Monitor (CPU, wakeups), Power Profiler and Time Profiler together, so every
# state is seen by all three at the same instants. System-wide, because on iOS the renderer's I/O runs in
# the audio daemons, not the app. The app starts once the recording has; the scenario takes 5 x 60 s.
rm -rf "$out/energy.trace" "$out/energy.log"
xcrun xctrace record --device "$udid" --template 'Activity Monitor' \
  --instrument 'Time Profiler' --instrument 'Power Profiler' \
  --all-processes --time-limit 345s --no-prompt --output "$out/energy.trace" > "$out/record.log" 2>&1 &
recorder=$!
sleep 15
xcrun devicectl device process launch --device "$udid" --terminate-existing --quiet \
  --environment-variables '{"PLAYBACK_ENERGY": "1"}' "$bundle" >/dev/null
wait "$recorder" || { cat "$out/record.log" >&2; fail "xctrace failed"; }

xcrun devicectl device copy from --device "$udid" --domain-type appDataContainer --domain-identifier "$bundle" \
  --source Documents/energy.log --destination "$out/energy.log" >/dev/null
python3 -I "$root/scripts/device-energy-summary.py" "$out"
