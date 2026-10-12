/*
 * id3_probe.c — stepping over the leading ID3v2 tag before libavformat reads anything.
 */
#include <string.h>

#include "decoder.h"

/* A reader's `STREAM_READ_*` failure as the open's status. */
static int probe_failure(int rc) {
    if (rc == STREAM_READ_CANCELLED) return STREAM_DECODE_ERR_CANCELLED;
    if (rc == STREAM_READ_INTERRUPTED) return STREAM_DECODE_ERR_INTERRUPTED;
    return STREAM_DECODE_ERR_IO;
}

/*
 * How many bytes of leading ID3v2 tag(s) to hide from libavformat.
 *
 * **This is the streaming player's largest single bandwidth cost, and it is not hypothetical.**
 * Measured on a published 108 MB MP3: a 13 782 278-byte
 * ID3v2 tag holding a 3000x3000 PNG cover, which `mp3_read_header` READS — not seeks over, because
 * it parses every APIC frame and turns the picture into an attached-pic stream nobody asked for.
 * `stream_decoder_open_with` cost 13.8 MB of cellular data before a note was heard. `probesize` does not
 * bound it: the tag is consumed before the demuxer ever gets to probe audio.
 *
 * So the tag is stepped over here and FFmpeg's byte 0 is the first MPEG frame. The decoder reports
 * no tag metadata or artwork; a caller that wants them reads the tag itself. Byte offsets the
 * caller sees (`stream_decoder_position_bytes`, the reader's positions) stay the SOURCE's, since
 * the translation lives in the AVIO callbacks and nowhere else.
 *
 * Returns STREAM_DECODE_OK with `base_offset` set to the absolute offset to start at and the
 * reader positioned there; on anything that is not ID3v2 that is 0, which is every m4a and most
 * mp3s. A read or seek cut short is the open's failure, never "no tag": the reader is left mid-tag,
 * and a dropped connection must not read as an unsupported format.
 */
int sd_probe_id3_offset(StreamDecoder *d) {
    int64_t offset = 0;
    int have = 0;   /* header bytes read at `offset` */
    uint8_t header[10];
    for (;;) {
        have = 0;
        while (have < (int)sizeof(header)) {
            int n = d->cb.read(d->opaque, header + have, (int)sizeof(header) - have);
            if (n == 0 || n == STREAM_READ_EOF) break;
            if (n < 0) return probe_failure(n);
            have += n;
        }
        if (have != (int)sizeof(header)) break;
        if (header[0] != 'I' || header[1] != 'D' || header[2] != '3') break;
        if (header[3] == 0xFF || header[4] == 0xFF) break;   /* not a version we can trust */
        /* Syncsafe: seven bits per byte, high bit always clear. */
        if ((header[6] | header[7] | header[8] | header[9]) & 0x80) break;
        int64_t size = ((int64_t)header[6] << 21) | ((int64_t)header[7] << 14)
                     | ((int64_t)header[8] << 7)  |  (int64_t)header[9];
        int64_t span = 10 + size + ((header[5] & 0x10) ? 10 : 0);   /* bit 4 is "has footer" */
        if (span <= 0) break;
        offset += span;
        /* Tags can be stacked; step to the next one and look again. */
        int rc = d->cb.seek(d->opaque, offset);
        if (rc == STREAM_READ_UNSEEKABLE) {
            /* A reader that refuses even a forward seek: the 10 header bytes are consumed, so
             * read and discard the rest of the tag (media3's DefaultExtractorInput.skip does the
             * same when it cannot seek). */
            int64_t left = span - (int64_t)sizeof(header);
            uint8_t sink[1024];
            while (left > 0) {
                int n = d->cb.read(d->opaque, sink, left < (int64_t)sizeof(sink) ? (int)left : (int)sizeof(sink));
                /* A tag that runs past the end leaves no audio. */
                if (n == 0 || n == STREAM_READ_EOF) return STREAM_DECODE_ERR_OPEN;
                if (n < 0) return probe_failure(n);
                left -= n;
            }
            rc = 0;
        }
        if (rc != 0) return probe_failure(rc);
    }
    /* Either there was no tag or the last read was past the last one: go back to where the media
     * (or the file) starts. */
    int rc = d->cb.seek(d->opaque, offset);
    if (rc == STREAM_READ_UNSEEKABLE) {
        /* A forward-only source cannot go back over the bytes just read; hand them to libavformat
         * from here instead of losing them (media3's DefaultExtractorInput peeks the same way). */
        memcpy(d->lead, header, (size_t)have);
        d->lead_len = have;
        d->lead_pos = 0;
    } else if (rc != 0) {
        return probe_failure(rc);
    }
    d->base_offset = offset;
    return STREAM_DECODE_OK;
}
