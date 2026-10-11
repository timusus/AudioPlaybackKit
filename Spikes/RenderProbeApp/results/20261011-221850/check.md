# PlaybackRender device check

iPhone iOS 26.6.1, started 2026-10-11T11:19:08Z, mic granted

| Scenario | Status | Result |
|---|---|---|
| A1 | pass | heard 4.001 s of 4; .ended 112.7 ms after the heard end; play -> heard 132 ms |
| A2 | pass | click heard 0.6 ms after the position said (spread 0.2 ms, 11 of 11 clicks); outputLatency 9.7 ms; position = clock - latency within 1.4 ms |
| A3 | measured | dropout 93 ms to 2x, 140 ms back (ADR: 97 / 140 ms); position runs at 2.00x; largest position jump 1 ms |
| A4 | measured | fixture 44.1k -> 48k dips ["10"] ms; 48k stereo -> 44.1k mono dip 10 ms (ADR: 8-11 ms); crossed 60 / 60 ms after the heard joins |
| A5 | fail | landed at 2.974 s of 12; sound back 228 ms after the call (silence 175 ms); position vs heard 2 s on 1.0 ms |
| A6 | pass | join dip 0 ms; crossed ["1", "2", "3"]; .ended 2x; setNext after .ended heard 108 ms later |
| A7 | inconclusive | no auto-flush on the port overrides |
| A8 | measured | rate 2.0: 0 flush(es), latency 9.7 -> 9.7 ms, jump 1 ms, clock back 50.1 ms / rate 1.0: 0 flush(es), latency 9.7 -> 9.7 ms, jump 0 ms, clock back 0.0 ms / rate 0.5: 0 flush(es), latency 9.7 -> 9.7 ms, jump 0 ms, clock back 0.0 ms; .ended after 4.29 s |
| A9 | measured | override speaker: 1 flush(es) (re-feed 33.594 ms vs heard, 36.994 vs flush time, silence <null> ms), latency 4.5 -> 9.7 ms, jump 0 ms, clock back 0.0 ms / override none: 1 flush(es) (re-feed 44.631 ms vs heard, 42.587 vs flush time, mic replay 291.208 ms, silence 0.0 ms), latency 9.7 -> 4.5 ms, jump 0 ms, clock back 0.0 ms / category playback: 1 flush(es) (re-feed 86.146 ms vs heard, 88.567 vs flush time), latency 4.5 -> 15.4 ms, jump 0 ms, clock back 3.3 ms / category playAndRecord: 1 flush(es) (re-feed 20.168 ms vs heard, 31.193 vs flush time, silence <null> ms), latency 15.4 -> 4.5 ms, jump 0 ms, clock back 0.0 ms; .ended after 2.26 s |
| A10 | measured | InterruptorApp: 0 flush(es), latency 15.4 -> 15.4 ms, jump 0 ms, clock back 59.4 ms; .ended after 2.35 s |
| G1 | skipped | skipped by --skip-guided |
| G2 | skipped | skipped by --skip-guided |
| G3 | skipped | skipped by --skip-guided |
| G4 | skipped | skipped by --skip-guided |
| G5 | skipped | skipped by --skip-guided |
| G6 | skipped | skipped by --skip-guided |
| G7 | skipped | skipped by --skip-guided |
