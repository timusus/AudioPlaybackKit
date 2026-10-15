# shellcheck shell=bash
#
# Sourced by build-ffmpeg.sh and package-ffmpeg-source.sh.
#
# fetch_ffmpeg_source TAG DEST — shallow-clone FFmpeg TAG into DEST, keeping .git.
# The 100+ MB clone from git.ffmpeg.org often dies mid-transfer, so retry, alternating with the
# official GitHub mirror. Each attempt starts from an empty DEST: git refuses a non-empty target.
fetch_ffmpeg_source() {
    local tag="$1" dest="$2" attempt url
    local urls=(https://git.ffmpeg.org/ffmpeg.git https://github.com/FFmpeg/FFmpeg.git)
    for attempt in 1 2 3 4; do
        url="${urls[(attempt - 1) % 2]}"
        rm -rf "$dest"
        mkdir -p "$(dirname "$dest")"
        if git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$url" "$dest"; then
            return 0
        fi
        echo "fetch-ffmpeg: attempt $attempt/4 from $url failed" >&2
        [[ "$attempt" == 4 ]] || sleep $((attempt * 5))
    done
    rm -rf "$dest"
    echo "fetch-ffmpeg: could not clone FFmpeg $tag after 4 attempts" >&2
    return 1
}
