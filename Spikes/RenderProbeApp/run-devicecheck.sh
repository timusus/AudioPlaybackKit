#!/bin/bash
# Builds the probe against this checkout's PlaybackRender, installs it on the paired iPhone over Wi-Fi,
# runs the device check (--check) and copies check.json, check.md, check.log and the mic WAVs into
# results/<timestamp>/. Extra arguments go to the app: --skip-guided runs the automatic scenarios only.
# Needs the phone unlocked and awake; the guided scenarios prompt on its screen.
set -euo pipefail
cd "$(dirname "$0")"
BUNDLE=com.simplecityapps.renderprobe
OUT="results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
exec > >(tee "$OUT/run.log") 2>&1

# Paired phones count as "available" over Wi-Fi too; DEVICE=<UDID> picks one.
DEVICE="${DEVICE:-$(xcrun devicectl list devices | grep physical | grep available | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1 || true)}"
[ -n "$DEVICE" ] || { echo "no paired iPhone available (same Wi-Fi, unlocked once since pairing?)"; exit 1; }
echo "device $DEVICE, app args: --check $*"

# The lease serialises builds on the owner's machine; elsewhere build directly.
LEASE=()
command -v lease >/dev/null && LEASE=(lease --class build --)
xcodegen generate --quiet
for scheme in RenderProbe InterruptorApp; do
  ${LEASE[@]+"${LEASE[@]}"} xcodebuild build -project RenderProbe.xcodeproj -scheme "$scheme" -destination "id=$DEVICE" \
    -derivedDataPath build -allowProvisioningUpdates -quiet
  xcrun devicectl device install app --device "$DEVICE" "build/Build/Products/Debug-iphoneos/$scheme.app"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
locked() {
  xcrun devicectl device info lockState --device "$DEVICE" -q -j "$TMP/lock.json" >/dev/null 2>&1 || return 0
  [ "$(plutil -extract result.passcodeRequired raw "$TMP/lock.json")" = "true" ]
}
if locked; then
  echo "iPhone is locked: unlock it within 2 minutes"
  sleep 120
  if locked; then echo "still locked; unlock it and rerun"; exit 3; fi
fi

xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE" --check "$@" >/dev/null
echo "launched; polling for check-done every 5 s (30 min cap)"

documents() {
  xcrun devicectl device info files --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --subdirectory Documents 2>/dev/null || true
}

# The app deletes the previous run's flags on launch, well before the first poll. A10 asks for
# InterruptorApp through a flag because only devicectl can start another app.
start=$(date +%s)
finished=no
interrupted=no
while [ $(( $(date +%s) - start )) -lt 1800 ]; do
  sleep 5
  listing="$(documents)"
  if grep -qE '(^|[[:space:]/])check-done([[:space:]]|$)' <<<"$listing"; then finished=yes; break; fi
  if [ "$interrupted" = no ] && grep -qE '(^|[[:space:]/])interruptor-wanted([[:space:]]|$)' <<<"$listing"; then
    interrupted=yes
    echo "  A10: launching InterruptorApp"
    xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE.interruptor" >/dev/null || echo "  InterruptorApp launch failed"
  fi
  elapsed=$(( $(date +%s) - start ))
  if [ $(( elapsed % 60 )) -lt 5 ]; then echo "  waiting ($(( elapsed / 60 )) min)"; fi
done

for file in check.json check.md check.log $(documents | grep -oE 'mic-check-[A-Za-z0-9]+\.wav' | sort -u); do
  xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "Documents/$file" --destination "$OUT/$file" -q || echo "could not copy $file"
done
[ "$finished" = yes ] || echo "no check-done after 30 min; copied what exists"
[ -f "$OUT/check.md" ] && cat "$OUT/check.md"
echo "results in $OUT"
[ "$finished" = yes ]
