# Render Probe: ADR-0018 device questions

Install (phone plugged in, unlocked, XcodeGen installed): `Spikes/RenderProbeApp/install.sh`

Volume up, silent switch off. Each button runs one test; the yellow box says what to listen for.
Stop ends a test. Share log sends the Documents log file (AirDrop, Files). Start tests with the screen on.

1. **1a**: no cables. Listen at each chirp (3, 6, 9, 12 s). Then force-quit and relaunch, run **1b** (preferred 48 kHz).
   Repeat both with wired headphones or a USB-C DAC if you have one (the hardware rate may differ).
2. **2**: tap the route button (top right), pick the AirPlay 2 speaker, then run. Compare the click with the clock.
   Tap TAP on each click you hear for ~10 clicks. Run it once more on the phone speaker as the baseline.
3. **3**: run it, then in turn, ~5 s apart: plug and unplug headphones, connect and disconnect Bluetooth,
   pick AirPlay and back to the phone, call the phone and decline, hold the side button for Siri.
   Note each action in your head; the log shows what fired and when.
4. **4a**, then **4b**: listen for a dropout at each rate change. Run on the speaker, then on Bluetooth if possible.
5. **5a**, then **5b**: 2 minutes each, speaker. Once with the screen on, once locking the phone 10 s in
   (audio keeps playing; unlock to read the log).
6. **6a** (hole) and **6b** (overlap): follow the text in the box.
7. **7**: run last, nothing to judge by ear; about 1 minute.

Then Share log and send it back with notes on what you heard per test (1a, 1b, 2, 3, 4a, 4b, 5a, 5b, 6a, 6b).

## Unattended

`Spikes/RenderProbeApp/run-auto.sh [UDID]` installs, launches with `--auto`, waits for the done flag (15 min
cap) and copies `results.json`, `auto.log` and the mic WAVs into `results/<timestamp>/`, then prints a
pass/fail table. Phone unlocked, on a table in a quiet room, silent switch off; the app sets the volume
to 0.75 and restores it. `ONLY=Q1a,Q2 run-auto.sh` runs a subset. The mic tests use `.playAndRecord` /
`.measurement` / `.defaultToSpeaker`; test C repeats the rate cycle and hole under `.playback`.

Not automatable, to observe later via app logging: a real phone call, Siri, picking an AirPlay route,
Bluetooth connect/disconnect, wired headphones.
