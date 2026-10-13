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

/* A block's first sample: 40 bits, the high byte apart from the rest. The wv demuxer reads only
 * the low 32 (ff_wv_parse_header) and labels the packet with them. */
static int64_t wv_index(const uint8_t *p) {
    return ((int64_t)p[10] << 32) | AV_RL32(p + 16);
}

/* Whether `p` is the header of a block that starts a frame (its first, for multichannel) and holds
 * audio, with that first sample's index, the block's sample count and its size after the size
 * field. `first` is the stream's first index, which `total` counts from. */
static int wv_block_header(const uint8_t *p, int64_t first, int64_t total, int64_t *index, int64_t *samples,
                           uint32_t *size) {
    if (AV_RL32(p) != MKTAG('w', 'v', 'p', 'k')) return 0;
    *size = AV_RL32(p + 4);
    unsigned version = AV_RL16(p + 8);
    uint32_t flags = AV_RL32(p + 24);
    if (*size < 24 || *size > (uint32_t)kWVBlockLimit || version < 0x402 || version > 0x410) return 0;
    if (!(flags & (1u << 11))) return 0;   /* WV_FLAG_INITIAL_BLOCK */
    *index = wv_index(p);
    *samples = AV_RL32(p + 20);
    return *samples > 0 && *index >= first && (total <= 0 || *index - first < total);
}

/* Whether a block header follows straight on from the block at `index` holding `samples`: the next
 * channel's of the same frame, or the next frame's. Audio that happens to read as a header has none. */
static int wv_block_followed(const uint8_t *next, int64_t index, int64_t samples) {
    if (AV_RL32(next) != MKTAG('w', 'v', 'p', 'k')) return 0;
    int64_t i = wv_index(next);
    return i == index || i == index + samples;
}

/* The first block to start at or after byte `at` (AVIO offset), believed when the block after it
 * starts where it ends or it ends the stream. Every block is at most `kWVBlockLimit` long, so the
 * block starts, and the next one ends, within twice that. `*pos` stays -1 when none was found (a
 * failed read, or no block before the end). Returns STREAM_DECODE_OK, or a cancel or an interruption. */
static int wv_block_after(StreamDecoder *d, int64_t at, int64_t first, int64_t total, int64_t *pos, int64_t *index,
                          int64_t *samples) {
    *pos = -1;
    int cap = 2 * (kWVBlockLimit + kWVHeaderBytes);
    if ((int64_t)cap > d->media_bytes - at) cap = (int)(d->media_bytes - at);
    if (cap < kWVHeaderBytes) return STREAM_DECODE_OK;
    uint8_t *buf = av_malloc((size_t)cap);
    if (!buf) return STREAM_DECODE_OK;
    int have = 0, scanned = 0;
    sd_avio_set_direct(d, 1);
    if (avio_seek(d->fmt->pb, at, SEEK_SET) >= 0) {
        while (*pos < 0) {
            for (; scanned + kWVHeaderBytes <= have; scanned++) {
                uint32_t size;
                if (!wv_block_header(buf + scanned, first, total, index, samples, &size)) continue;
                int64_t next = scanned + (int64_t)size + 8;
                if ((total > 0 && *index + *samples >= first + total)
                    || (next + kWVHeaderBytes <= have && wv_block_followed(buf + next, *index, *samples))) {
                    *pos = at + scanned;
                    break;
                }
                if (next + kWVHeaderBytes > have && have < cap) break;   /* read on to its successor */
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
 * the stream's bytes and stepping back, twice as far each time, while the probe finds no block or
 * one that starts after the target. `plan->anchor_pos` stays -1 when the stream has no length or
 * the probes find none. A block further before the target than a seek may decode lands where it
 * is, as a FLAC frame does.
 */
static int wv_place(StreamDecoder *d, int64_t target, SeekPlan *plan) {
    if (!sd_can_estimate_bytes(d)) return STREAM_DECODE_OK;
    AVStream *st = d->fmt->streams[d->audio_idx];
    AVRational per_sample = { 1, st->codecpar->sample_rate };
    int64_t total = st->duration > 0 ? av_rescale_q(st->duration, st->time_base, per_sample)
                                     : llround(d->media_duration * per_sample.den);
    /* Packets carry the block's own index, so the target is on that base, the first block's index
     * where the stream starts. */
    int64_t first = d->first_pkt_dts != AV_NOPTS_VALUE
                        ? av_rescale_q(d->first_pkt_dts - d->start_time, d->time_base, per_sample) : 0;
    int64_t want = av_rescale_q(target - d->start_time, d->time_base, per_sample);
    if (want < first) want = first;
    if (total > 0 && want > first + total) want = first + total;
    double bytes_per_sample = (double)d->media_bytes / (double)(total > 0 ? total : 1);
    int64_t at = (int64_t)((want - first) * bytes_per_sample);

    for (int probe = 0; probe < kWVProbes; probe++) {
        int64_t pos, index, samples;
        int rc = wv_block_after(d, at, first, total, &pos, &index, &samples);
        if (rc != STREAM_DECODE_OK) return rc;
        if (pos >= 0 && index <= want) {
            plan->anchor_pos = pos;
            plan->anchor_dts = d->start_time + av_rescale_q(index, per_sample, d->time_base);
            if ((double)(want - index) * bytes_per_sample > (double)kSeekBudgetBytes) plan->land_at = plan->anchor_dts;
            /* The generic seek reads on from the index's last entry rather than going to it: an
             * entry at the end keeps the anchor off the end, as for FLAC. */
            int64_t end_dts = d->start_time + av_rescale_q(first + total, per_sample, d->time_base);
            if (end_dts > plan->anchor_dts) av_add_index_entry(st, d->media_bytes, end_dts, 0, 0, AVINDEX_KEYFRAME);
            return STREAM_DECODE_OK;
        }
        if (at == 0) return STREAM_DECODE_OK;
        /* Back from the block found by its distance past the target and one block more; with none
         * found, the target's block starts before everything this probe read. */
        int64_t from = pos >= 0 ? pos : at;
        int64_t back = pos >= 0 ? (int64_t)((double)(index - want + samples) * bytes_per_sample)
                                : d->media_bytes - at;
        back <<= probe;
        at = from > back ? from - back : 0;
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
