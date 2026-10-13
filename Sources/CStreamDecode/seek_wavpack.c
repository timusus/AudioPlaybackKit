/*
 * seek_wavpack.c — how a WavPack stream seeks (see seek.h).
 *
 * The wv demuxer has no seek of its own: libavformat walks its packets from the last one indexed,
 * which outruns the seek budget within a second or two of lossless audio, and it cannot find a
 * block from an arbitrary byte, so the byte estimate leaves it mid-block and every read after fails.
 * A block header carries the index of its first sample, so a probe near the estimate finds a block
 * whose place and time are both known and the seek anchors on it. media3 has no WavPack extractor;
 * the bounded probe follows its FLAC seekers.
 */
#include <libavutil/intreadwrite.h>
#include <libavutil/mathematics.h>

#include "decoder.h"

/* The wv demuxer's limits: its largest block (WV_BLOCK_LIMIT) and its header's size. */
static const int kWVBlockLimit = 1 << 20;
enum { kWVHeaderBytes = 32 };

/* Probes before a seek gives up its anchor and leaves the demuxer's walk to place it. */
static const int kWVProbes = 8;

/* Whether `p` is the header of a block that starts a frame (its first, for multichannel) and holds
 * audio, with that first sample's index and the block's sample count. The wv demuxer reads the
 * same fields (ff_wv_parse_header) and labels the packet with that 32-bit index. */
static int wv_block_header(const uint8_t *p, int64_t total, int64_t *index, int64_t *samples) {
    if (AV_RL32(p) != MKTAG('w', 'v', 'p', 'k')) return 0;
    uint32_t size = AV_RL32(p + 4);
    unsigned version = AV_RL16(p + 8);
    uint32_t flags = AV_RL32(p + 24);
    if (size < 24 || size > (uint32_t)kWVBlockLimit || version < 0x402 || version > 0x410) return 0;
    if (!(flags & (1u << 11))) return 0;   /* WV_FLAG_INITIAL_BLOCK */
    *index = AV_RL32(p + 16);
    *samples = AV_RL32(p + 20);
    return *samples > 0 && (total <= 0 || *index < total);
}

/* The first block to start at or after byte `at` (AVIO offset): every block is at most
 * `kWVBlockLimit` long, so it starts within that. `*pos` stays -1 when none was found (a failed read,
 * or no block before the end). Returns STREAM_DECODE_OK, or a cancel or an interruption. */
static int wv_block_after(StreamDecoder *d, int64_t at, int64_t total, int64_t *pos, int64_t *index,
                          int64_t *samples) {
    *pos = -1;
    int cap = kWVBlockLimit + kWVHeaderBytes;
    if ((int64_t)cap > d->media_bytes - at) cap = (int)(d->media_bytes - at);
    if (cap < kWVHeaderBytes) return STREAM_DECODE_OK;
    uint8_t *buf = av_malloc((size_t)cap);
    if (!buf) return STREAM_DECODE_OK;
    int have = 0, scanned = 0;
    sd_avio_set_direct(d, 1);
    if (avio_seek(d->fmt->pb, at, SEEK_SET) >= 0) {
        while (*pos < 0) {
            for (; scanned + kWVHeaderBytes <= have; scanned++) {
                if (wv_block_header(buf + scanned, total, index, samples)) {
                    *pos = at + scanned;
                    break;
                }
            }
            if (*pos >= 0 || have == cap) break;
            int ask = cap - have < 4096 ? cap - have : 4096;
            int got = avio_read(d->fmt->pb, buf + have, ask);
            if (got <= 0) break;
            have += got;
        }
    }
    sd_avio_set_direct(d, 0);
    av_free(buf);
    return sd_read_failure_status(d);
}

/*
 * The block at or before `target` (stream time base), found by probing at the target's share of
 * the stream's bytes and stepping back, twice as far each time, while the block found starts after
 * the target. `plan->anchor_pos` stays -1 when the stream has no length or the probes find none.
 */
static int wv_place(StreamDecoder *d, int64_t target, SeekPlan *plan) {
    if (!sd_can_estimate_bytes(d)) return STREAM_DECODE_OK;
    AVStream *st = d->fmt->streams[d->audio_idx];
    AVRational per_sample = { 1, st->codecpar->sample_rate };
    int64_t total = st->duration > 0 ? av_rescale_q(st->duration, st->time_base, per_sample)
                                     : llround(d->media_duration * per_sample.den);
    int64_t want = av_rescale_q(target - d->start_time, d->time_base, per_sample);
    if (want < 0) want = 0;
    if (total > 0 && want > total) want = total;
    double bytes_per_sample = (double)d->media_bytes / (double)(total > 0 ? total : 1);
    int64_t at = (int64_t)(want * bytes_per_sample);

    for (int probe = 0; probe < kWVProbes; probe++) {
        int64_t pos, index, samples;
        int rc = wv_block_after(d, at, total, &pos, &index, &samples);
        if (rc != STREAM_DECODE_OK || pos < 0) return rc;
        if (index <= want) {
            plan->anchor_pos = pos;
            plan->anchor_dts = d->start_time + av_rescale_q(index, per_sample, d->time_base);
            /* The generic seek reads on from the index's last entry rather than going to it: an
             * entry at the end keeps the anchor off the end, as for FLAC. */
            int64_t end_dts = d->start_time + av_rescale_q(total, per_sample, d->time_base);
            if (end_dts > plan->anchor_dts) av_add_index_entry(st, d->media_bytes, end_dts, 0, 0, AVINDEX_KEYFRAME);
            return STREAM_DECODE_OK;
        }
        if (at == 0) return STREAM_DECODE_OK;
        int64_t back = (int64_t)((double)(index - want + samples) * bytes_per_sample) << probe;
        at = at > back ? at - back : 0;
    }
    return STREAM_DECODE_OK;
}

/* Never the byte estimate: it would leave the demuxer mid-block. */
static int wv_has_estimate_anchor(const StreamDecoder *d) {
    return sd_can_estimate_bytes(d);
}

static int wv_place_by_estimate(StreamDecoder *d, double ratio, int64_t target, SeekPlan *plan) {
    (void)ratio;
    return wv_place(d, target, plan);
}

const SeekFormat sd_seek_wavpack = {
    .name = "wavpack",
    .place = wv_place,
    .has_estimate_anchor = wv_has_estimate_anchor,
    .estimate_anchor = wv_place_by_estimate,
};
