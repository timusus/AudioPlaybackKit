# PlaybackRender device check

iPhone iOS 26.6.1, started 2026-10-11T11:40:32Z, mic granted

| Scenario | Status | Result |
|---|---|---|
| G3 | fail | fired: AirPlay:Timothy’s MacBook Pro; 1 auto-flush(es) ["re-feed 1939.428 ms vs heard"]; latency 15.354 -> 2000.0 ms; position rate 1.00, stall 2451 ms; picker opened 2.4 s after play, route fired 4.4 s; 2 position stall(s) over 250 ms; heard dips before the route fired: 1 (first at 1.55 s after picker open, 454 ms); .ended never; owner: No glitch |
| G4 | pass | fired: Speaker:Speaker; 1 auto-flush(es) ["re-feed 5.793 ms vs heard"]; latency 2000.0 -> 15.354 ms; position rate 1.00, stall 376 ms; picker opened 1.6 s after play, route fired 7.6 s; 2 position stall(s) over 250 ms; heard dips before the route fired: 1 (first at 5.65 s after picker open, 308 ms); .ended after 2.34 s; owner: Gap or click |
