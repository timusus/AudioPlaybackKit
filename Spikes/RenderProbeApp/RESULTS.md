# Render Probe results (ADR-0018 device questions)

iPhone (00008140-000539602E90401C), iOS 26.6.1, phone speaker, quiet room, volume 0.75.
Run: `results/20261011-081100/` (`results.json`, `auto.log`; WAVs kept locally, not committed).
Mic tests: `.playAndRecord` / `.measurement` / `.defaultToSpeaker`, 1 kHz tone, SNR 32-46 dB.
Glitch = envelope dip over 6 dB for 5 ms or more, or a phase step over 1 rad between steady stretches.
Tags: **measured** (mic or API), **inferred** (reasoned from measurements), **not automatable**.

**Q1 Sample-rate change mid-stream: audible?** Measured: yes, a short dip at most joins, the same with
preferred rate unset and 48 kHz. 44.1k mono→48k stereo 11 ms, 48k→96k 10 ms, 96k→192k none,
192k stereo→44.1k mono 8 ms. Hardware rate stayed 48 kHz throughout; no route or configuration event.
Inferred: the renderer re-primes its converter on a format change; a decoder that resamples to one
format before enqueueing would avoid it.

**Q2 Does `currentTime()` match what is heard?** Measured: the click is heard 11.0 ms after
`currentTime()` reaches its PTS (mic `inputLatency` 0.6 ms already subtracted), spread under 0.1 ms
over 11 clicks. `outputLatency` is 9.7 ms, leaving 1.3 ms unexplained. Inferred: `currentTime()`
excludes output latency; add `outputLatency` for a UI that must line up with sound (lyrics, chapters).

**Q3 Route and session changes in code.** Measured, all with playback still rendering afterwards:
- `overrideOutputAudioPort(.speaker)` and `(.none)`: routeChange (override / categoryChange) and
  `wasFlushedAutomatically` within 10 ms; the renderer resumes itself.
- `.playAndRecord` → `.playback` and back: routeChange plus an auto-flush each.
- `setActive(false)` then `(true)` while rendering: a routeChange each, no error, no flush; audio carried on.
- `setPreferredSampleRate` 44.1k / 48k / 96k: no event; hardware rate stayed 48 kHz.
- No output-configuration-change notification in any step.
Not automatable (observe via app logging later): a real call, Siri, AirPlay picking, Bluetooth, wired headphones.

**Q4 Rate 1→2→1: dropout?** Measured: yes, at each change. Spectral time-pitch: 186 ms gap going to 2x,
327 ms going back to 1x. TimeDomain: 97 ms and 140 ms. The rate setter itself blocks 33-53 ms. The control
under `.playback` (no mic) shows the same renderer-side clock behaviour, so the category is not the cause.
Inferred: a rate change re-runs the time-pitch with a refill; prefer TimeDomain for speech if 100 ms is OK.

**Q5 Default pull (`requestMediaDataWhenReady`) vs 2 s depth: glitches over 40 s?** Measured: none in
either; no dips, no phase splices. Depth does not matter on the speaker with the screen on.
Not automatable: the same with the phone locked (the app has no background audio mode).

**Q6 PTS hole and overlap.** Measured:
- Hole (1 kHz 0-3 s, 2 kHz 4-7 s): 0.999 s of silence; the hole is honoured, second tone starts on its PTS (+12 ms).
- Overlap (2 kHz stamped at 2.5 s): the 1 kHz plays all 3 s, the 2 kHz plays only 2.5 s from 3.0 s.
  The overlapped 0.5 s is dropped, not mixed or shifted.
Inferred: the renderer trims late audio to the timeline, so a decoder's PTS must be right; gaps play as silence.

**Q7 Blocking cost, main vs background queue (median of 6).** Measured:
- `renderer.flush()`: 74 ms on main, 80 ms on background.
- `synchronizer.rate = 2 / = 1`: 47 / 43 ms on main, 41 / 49 ms on background.
- `AVAudioPlayerNode.stop()`: 1.3 ms on either.
Inferred: flush and rate changes block for several frames; keep them off the main thread in seek and
speed controls.

**Control (C).** Measured: rate cycle and hole under `.playback` match `.playAndRecord`
(media/wall 1, 2, 1; same auto-flush counts).
