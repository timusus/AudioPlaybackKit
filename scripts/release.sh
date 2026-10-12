#!/usr/bin/env bash
#
# release.sh X.Y.Z NOTES.md — test, tag, push and publish a release that consumers can pin.
#
# Runs from any checkout, in its own detached worktree at origin/main (.claude/worktrees/release), and refuses
# a malformed or existing tag and a red `swift test`. Tags are bare semver (0.1.0), which is what SwiftPM's `from:` resolves.
# Writes dist/ffmpeg-X.Y.Z-source.tar.xz (package-ffmpeg-source.sh: FFmpeg tree, patches, build script) and
# publishes the GitHub release with NOTES.md as its body and the tarball attached.
set -euo pipefail

version="${1:-}"
notes="${2:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! -s "$notes" ]]; then
    echo "usage: scripts/release.sh X.Y.Z NOTES.md (non-empty release notes)" >&2
    exit 2
fi
notes="$(cd "$(dirname "$notes")" && pwd)/$(basename "$notes")"
# Checked before the tests, so a tag is never pushed without its release.
gh auth status >/dev/null 2>&1 || { echo "release.sh: gh is not authenticated" >&2; exit 1; }

cd "$(dirname "$0")/.."

if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
    echo "release.sh: tag $version already exists" >&2
    exit 1
fi

git fetch --quiet origin
git rev-parse -q --verify origin/main >/dev/null || { echo "release.sh: no origin/main" >&2; exit 1; }

# Own worktree, never the landing one: moving that mid-land invalidates the verify.
# Only landed work is released, so it is always exactly origin/main.
common="$(git rev-parse --path-format=absolute --git-common-dir)"
release_tree="$(dirname "$common")/.claude/worktrees/release"
if [[ -d "$release_tree" ]]; then
    git -C "$release_tree" reset --quiet --hard
    git -C "$release_tree" clean --quiet -fd
    git -C "$release_tree" checkout --quiet --detach origin/main
else
    git worktree add --quiet --detach "$release_tree" origin/main
fi
cd "$release_tree"

# The published source must match the binary: VERSION.txt records the patches it was built with.
recorded_patches="$(sed -n 's/^patch-sha256: //p' Frameworks/FFmpeg.xcframework/VERSION.txt | LC_ALL=C sort)"
actual_patches="$(cd scripts/ffmpeg-patches && { shasum -a 256 *.patch 2>/dev/null || true; } | awk '{print $1 " " $2}' | LC_ALL=C sort)"
if [[ "$recorded_patches" != "$actual_patches" ]]; then
    echo "release.sh: scripts/ffmpeg-patches differs (by content) from the patches recorded in the framework's VERSION.txt; rebuild the framework" >&2
    exit 1
fi
# Likewise the configure flags and the export list: both change the binary without touching a patch.
version_txt="${VERSION_TXT:-Frameworks/FFmpeg.xcframework/VERSION.txt}"
if [[ "$(sed -n 's/^configured: //p' "$version_txt")" != "$(PRINT_CONFIGURED=1 scripts/build-ffmpeg.sh)" ]]; then
    echo "release.sh: build-ffmpeg.sh configure flags differ from the 'configured:' line of VERSION.txt; rebuild the framework" >&2
    exit 1
fi
if ! grep -qF "exports only $(tr '\n' ' ' < scripts/ffmpeg-exports.txt)(ffmpeg-exports.txt)" "$version_txt"; then
    echo "release.sh: scripts/ffmpeg-exports.txt differs from the exports recorded in VERSION.txt; rebuild the framework" >&2
    exit 1
fi

echo "release.sh: swift test"
swift test

# The byte source runs on iOS URLSession in the apps, so its tests also run on a simulator,
# on a device of its own (IOS_SIM_UDID overrides): another repo's parallel-testing xcodebuild clones
# the shared iPhone, which shuts it down mid-suite (timusus/devtools#23).
sim_name="AudioPlaybackKit Verify"
devices="$(xcrun simctl list devices available -j)"
udid="${IOS_SIM_UDID:-$(jq -r --arg n "$sim_name" '[.devices[][] | select(.name == $n)][0].udid // empty' <<<"$devices")}"
if [[ -z "$udid" ]]; then
    read -r runtime devtype < <(jq -r '[.devices | to_entries[] | select(.key | test("iOS")) | .key as $r
        | .value[] | select(.name | startswith("iPhone")) | "\($r) \(.deviceTypeIdentifier)"] | last // empty' <<<"$devices")
    if [[ -z "${runtime:-}" ]]; then
        echo "release.sh: no iPhone simulator to model '$sim_name' on; set IOS_SIM_UDID" >&2
        exit 1
    fi
    udid="$(xcrun simctl create "$sim_name" "$devtype" "$runtime")"
fi
echo "release.sh: PlaybackStreamingTests on iOS simulator $udid"
xcodebuild test -scheme AudioPlaybackKit-Package -only-testing:PlaybackStreamingTests \
    -destination "platform=iOS Simulator,id=$udid" -quiet

# Built before tagging, so a tag never lacks its source (LGPL-2.1 section 6); a failed or
# interrupted run leaves no partial tarball.
source_name="ffmpeg-$version-source"
packaged=0
trap '[[ "$packaged" == 1 ]] || rm -f "dist/$source_name.tar.xz"' EXIT
scripts/package-ffmpeg-source.sh "$version"
packaged=1

git tag -a "$version" -m "AudioPlaybackKit $version"
if ! git push origin "$version"; then
    git tag -d "$version" >/dev/null
    echo "release.sh: pushing tag $version failed; local tag removed, rerun to retry" >&2
    exit 1
fi
gh release create "$version" --verify-tag --title "$version" --notes-file "$notes" "dist/$source_name.tar.xz"
echo "release.sh: released $version ($(git rev-parse --short HEAD))"
