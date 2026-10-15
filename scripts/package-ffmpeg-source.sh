#!/usr/bin/env bash
#
# package-ffmpeg-source.sh X.Y.Z [OUT_DIR] — pack dist/ffmpeg-X.Y.Z-source.tar.xz (default OUT_DIR=dist).
#
# LGPL-2.1 section 6: the apps embed this release's FFmpeg, so its exact source, patches and build
# recipe are published beside it. The tarball is laid out like the repo (scripts/, the FFmpeg tree
# beside it), so scripts/build-ffmpeg.sh runs unchanged from the extracted directory. release.sh
# calls this before tagging; it can be run alone to check the tarball rebuilds.
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: scripts/package-ffmpeg-source.sh X.Y.Z [OUT_DIR]" >&2
    exit 2
fi

cd "$(dirname "$0")/.."
out_dir="${2:-dist}"

ffmpeg_tag="$(head -1 Frameworks/FFmpeg.xcframework/VERSION.txt)"
# build-ffmpeg.sh looks for ffmpeg-<its FFMPEG_TAG default>/ beside scripts/; a tree named for another tag would be ignored.
build_tag="$(sed -n 's/^FFMPEG_TAG="${FFMPEG_TAG:-\(.*\)}"$/\1/p' scripts/build-ffmpeg.sh)"
if [[ -z "$build_tag" || "$build_tag" != "$ffmpeg_tag" ]]; then
    echo "package-ffmpeg-source: VERSION.txt says '$ffmpeg_tag' but build-ffmpeg.sh defaults FFMPEG_TAG to '${build_tag:-?}'; rebuild the framework" >&2
    exit 1
fi
source_name="ffmpeg-$version-source"
archive="$out_dir/$source_name.tar.xz"
staging="$(mktemp -d)"
done_ok=0
cleanup() {
    rm -rf "$staging" "$staging.list"
    [[ "$done_ok" == 1 ]] || rm -f "$archive"
}
trap cleanup EXIT

echo "package-ffmpeg-source: FFmpeg $ffmpeg_tag source as $archive"
root="$staging/$source_name"
# The fetch is flaky and runs after the 30-minute test run, so keep the tree per tag across releases.
cache_dir="${XDG_CACHE_HOME:-$HOME/Library/Caches}/AudioPlaybackKit"
cache="$cache_dir/ffmpeg-$ffmpeg_tag.tar"
mkdir -p "$root"
if [[ -f "$cache" ]] && tar -xf "$cache" -C "$root"; then
    echo "package-ffmpeg-source: using cached $cache"
else
    # A corrupt cache may have half-extracted; start clean.
    rm -rf "$root/ffmpeg-$ffmpeg_tag"
    . scripts/lib/fetch-ffmpeg.sh
    fetch_ffmpeg_source "$ffmpeg_tag" "$root/ffmpeg-$ffmpeg_tag"
    rm -rf "$root/ffmpeg-$ffmpeg_tag/.git"
    # Temp file plus mv, so an interrupted write never leaves a partial cache.
    mkdir -p "$cache_dir"
    cache_tmp="$(mktemp "$cache_dir/.ffmpeg-$ffmpeg_tag.XXXXXX")"
    tar -cf "$cache_tmp" -C "$root" "ffmpeg-$ffmpeg_tag"
    mv "$cache_tmp" "$cache"
fi
# Without .git, ffbuild/version.sh embeds an empty FFMPEG_VERSION; a VERSION file restores the git-describe string (the tag).
echo "$ffmpeg_tag" > "$root/ffmpeg-$ffmpeg_tag/VERSION"
mkdir -p "$root/scripts"
cp -R scripts/ffmpeg-patches "$root/scripts/ffmpeg-patches"
cp scripts/build-ffmpeg.sh scripts/ffmpeg-exports.txt "$root/scripts/"
cp -R scripts/lib "$root/scripts/lib"
cp Frameworks/FFmpeg.xcframework/VERSION.txt "$root/"
cat > "$root/README.txt" <<README
FFmpeg $ffmpeg_tag source, local patches and build recipe for AudioPlaybackKit $version.

Rebuild the dynamic framework (macOS, Xcode with the iOS SDKs):

    scripts/build-ffmpeg.sh

It finds the FFmpeg tree in ffmpeg-$ffmpeg_tag/ beside scripts/ (or at \$FFMPEG_SRC), applies
scripts/ffmpeg-patches/ and writes Frameworks/FFmpeg.xcframework. VERSION.txt records the configure
flags and patch hashes of the shipped binary.
README

mkdir -p "$out_dir"
# Reproducible archive (bsdtar): sorted members, the commit's date as mtime, root ownership.
stamp="$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y%m%d%H%M.%S HEAD)"
(cd "$staging" && find "$source_name" -exec touch -h -t "$stamp" {} + && find "$source_name" | LC_ALL=C sort > "$staging.list")
tar -cJf "$archive" -C "$staging" --no-recursion --uid 0 --gid 0 --numeric-owner -T "$staging.list"
done_ok=1
