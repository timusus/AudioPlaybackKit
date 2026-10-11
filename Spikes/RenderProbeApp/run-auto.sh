#!/bin/sh
# Installs the probe, runs every automatable test unattended (--auto) on the connected iPhone, and copies
# results.json and auto.log into results/<timestamp>/. Needs the phone unlocked; volume up helps the mic tests.
set -e
cd "$(dirname "$0")"
DEVICE="${1:-$(xcrun devicectl list devices | grep -E 'physical' | grep -E 'available' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)}"
[ -n "$DEVICE" ] || { echo "no connected iPhone" >&2; exit 1; }
BUNDLE=com.simplecityapps.renderprobe
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

locked() {
  xcrun devicectl device info lockState --device "$DEVICE" -q -j "$TMP/lock.json" >/dev/null 2>&1 || return 0
  [ "$(plutil -extract result.passcodeRequired raw "$TMP/lock.json")" = "true" ]
}

./install.sh "$DEVICE"

if locked; then
  echo "iPhone is locked; retrying in 2 minutes"
  sleep 120
  if locked; then echo "iPhone is locked: unlock it and rerun" >&2; exit 3; fi
fi

xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE" --auto ${ONLY:+--only=$ONLY} >/dev/null
echo "launched with --auto; polling for the done flag (every 10 s, 15 min cap)"

documents() {
  xcrun devicectl device info files --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --subdirectory Documents 2>/dev/null
}

# The app deletes the previous run's flag on launch, well before the first poll.
start=$(date +%s)
done=no
while [ $(( $(date +%s) - start )) -lt 900 ]; do
  sleep 10
  if documents | grep -qE '(^|[[:space:]/])done([[:space:]]|$)'; then done=yes; break; fi
  printf '.'
done
echo

OUT="results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
for file in results.json auto.log $(documents | grep -oE 'mic-[A-Za-z0-9]+\.wav' | sort -u); do
  xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "Documents/$file" --destination "$OUT/$file" -q || echo "could not copy $file" >&2
done
[ "$done" = yes ] || echo "no done flag after 15 min; copied what exists" >&2
[ -f "$OUT/results.json" ] || exit 2

python3 -I - "$OUT/results.json" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
print(f"{r['device']} iOS {r['ios']}, mic {r['micPermission']}, complete {r['complete']}")
for t in r["tests"]:
    print(f"{t['id']:<4} {t.get('status', '?'):<12} {t.get('verdict', '')}")
EOF
echo "results in $OUT"
[ "$done" = yes ]
