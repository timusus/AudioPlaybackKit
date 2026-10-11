# PlaybackRender device check

iPhone iOS 26.6.1, started 2026-10-11T11:24:55Z, mic granted

| Scenario | Status | Result |
|---|---|---|
| A1 | pass | heard 4.000 s of 4; .ended 113.4 ms after the heard end; play -> heard 131 ms |
| A2 | pass | click heard 0.7 ms after the position said (spread 0.4 ms, 11 of 11 clicks); outputLatency 9.7 ms; position = clock - latency within 1.6 ms |
| A3 | measured | dropout 93 ms to 2x, 140 ms back (ADR: 97 / 140 ms); position runs at 2.00x; largest position jump 1 ms |
| A4 | measured | fixture 44.1k -> 48k dips ["9"] ms; 48k stereo -> 44.1k mono dip 10 ms (ADR: 8-11 ms); crossed 73 / 74 ms after the heard joins |
| A5 | fail | landed at 2.970 s of 12; sound back 232 ms after the call (silence 174 ms); position vs heard 2 s on 0.7 ms |
| A6 | pass | join dip 0 ms; crossed ["1", "2", "3"]; .ended 2x; setNext after .ended heard 30 ms later |
| A7 | inconclusive | no auto-flush on the port overrides |
| A8 | measured | rate 2.0: 0 flush(es), latency 9.7 -> 9.7 ms, jump 1 ms, clock back 55.7 ms / rate 1.0: 0 flush(es), latency 9.7 -> 9.7 ms, jump 88 ms, clock back 0.0 ms / rate 0.5: 0 flush(es), latency 9.7 -> 9.7 ms, jump 0 ms, clock back 0.0 ms; .ended after 4.29 s |
| A9 | measured | override speaker: 1 flush(es) (re-feed 14.731 ms vs heard, 35.559 vs flush time, silence <null> ms), latency 4.5 -> 9.7 ms, jump 0 ms, clock back 0.0 ms / override none: 1 flush(es) (re-feed 52.836 ms vs heard, 51.057 vs flush time, mic replay 295.999 ms, silence 0.0 ms), latency 9.7 -> 4.5 ms, jump 0 ms, clock back 0.0 ms / category playback: 1 flush(es) (re-feed 108.789 ms vs heard, 101.551 vs flush time), latency 4.5 -> 15.4 ms, jump 0 ms, clock back 3.3 ms / category playAndRecord: 1 flush(es) (re-feed 22.59 ms vs heard, 32.843 vs flush time, mic replay -28.125 ms, silence 27.0 ms), latency 15.4 -> 4.5 ms, jump 0 ms, clock back 0.0 ms; .ended after 2.29 s |
| A10 | measured | InterruptorApp: 0 flush(es), latency 15.4 -> 15.4 ms, jump 0 ms, clock back 54.9 ms; .ended after 2.33 s |
| G1 | pass | fired: BluetoothA2DPOutput:JBL Charge 3; 1 auto-flush(es) ["re-feed 33.412 ms vs heard"]; latency 15.354 -> 83.265 ms; position rate 1.00, stall 465 ms; .ended after 2.44 s; owner: No glitch |
| G2 | pass | fired: Speaker:Speaker; 1 auto-flush(es) ["re-feed -0.262 ms vs heard"]; latency 83.265 -> 15.354 ms; position rate 1.00, stall 302 ms; .ended after 2.34 s; owner: No glitch |
| G3 | pass | fired: AirPlay:Timothy’s MacBook Pro; 1 auto-flush(es) ["re-feed 1967.322 ms vs heard"]; latency 15.354 -> 2000.0 ms; position rate 1.00, stall 2447 ms; .ended after 4.41 s; owner: No glitch |
| G4 | pass | fired: Speaker:Speaker; 1 auto-flush(es) ["re-feed 83.742 ms vs heard"]; latency 2000.0 -> 15.354 ms; position rate 1.00, stall 281 ms; .ended after 2.34 s; owner: Gap or click |
| G6 | pass | fired: no interruption; 0 auto-flush(es) []; latency 15.354 -> 15.354 ms; position rate 1.00, stall 104 ms; .ended after 2.34 s; owner: No glitch |
| G7 | pass | fired: media services reset; 0 auto-flush(es) []; latency 15.354 -> 15.354 ms; position rate 1.00, stall 103 ms; .ended after 2.34 s; owner: No glitch |
