#!/usr/bin/env bash
#
# Prints the signing team for device builds: DEVELOPMENT_TEAM, else the Simplecity team from the
# keychain, else the only team there. Each Apple certificate's OU is its team.
set -euo pipefail

team="${DEVELOPMENT_TEAM:-}"
if [ -z "$team" ]; then
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  security find-certificate -a -c "Apple D" -p | awk -v dir="$scratch" '/BEGIN/ { n++ } { print > (dir "/cert" n ".pem") }'
  teams="$(for pem in "$scratch"/cert*.pem; do
    openssl x509 -noout -subject -in "$pem" | sed -n 's/.*OU *= *\([A-Z0-9]*\), *O *= *\([^,]*\).*/\1 \2/p'
  done | sort -u)"
  team="$(echo "$teams" | awk '/Simplecity/ { print $1; exit }')"
  [ -n "$team" ] || [ "$(echo "$teams" | wc -l)" -ne 1 ] || team="$(echo "$teams" | awk '{ print $1 }')"
  [ -n "$team" ] || { echo "cannot pick a team from the keychain; set DEVELOPMENT_TEAM. Found: $teams" >&2; exit 1; }
fi
echo "$team"
