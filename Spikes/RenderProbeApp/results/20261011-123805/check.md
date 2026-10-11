# PlaybackRender device check

iPhone iOS 26.6.1, started 2026-10-11T01:40:16Z, mic granted

| Scenario | Status | Result |
|---|---|---|
| A1 | fail | heard 4.050 s of 4; .ended 162.8 ms after the heard end; play -> heard 266 ms |
| A2 | fail | click heard -17.8 ms after the position said (spread 151.4 ms, 11 clicks); outputLatency 9.7 ms; position = clock - latency within 1.4 ms |
| A3 | measured | dropout 51 ms to 2x, 139 ms back (ADR: 97 / 140 ms); position runs at 2.00x; largest position jump 1 ms |
| A4 | measured | fixture 44.1k -> 48k dips [] ms; 48k stereo -> 44.1k mono dip 0 ms (ADR: 8-11 ms); crossed 72 / 73 ms after the heard joins |
| A5 | pass | landed at 12.000 s of 12; sound back 375 ms after the call (silence 339 ms); position vs heard 2 s on 1.8 ms |
| A6 | pass | join dip 0 ms; crossed ["1", "2", "3"]; .ended 2x; setNext after .ended heard 108 ms later |
| A7 | inconclusive | no auto-flush on the port overrides |
| G1 | skipped | skipped by --skip-guided |
| G2 | skipped | skipped by --skip-guided |
| G3 | skipped | skipped by --skip-guided |
| G4 | skipped | skipped by --skip-guided |
| G5 | skipped | skipped by --skip-guided |
| G6 | skipped | skipped by --skip-guided |
| G7 | skipped | skipped by --skip-guided |
| G8 | skipped | skipped by --skip-guided |
| G9 | skipped | skipped by --skip-guided |
