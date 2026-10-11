# Device checklist

What no test covers: the real `AVAudioSession`, `MPRemoteCommandCenter`, routes and AirPlay. Run it on an
iPhone before relying on a release, with a build that plays a list of at least three items (an album or a
few episodes) through `Player` and `NowPlayingSession`. Record what passed and failed in the release's
tracking issue; fix this list when a step is wrong or a case is missing.

"Playing" means the audio is audible and `isPlaying` is true. "Paused" means silent, `playWhenReady` is
false, and the lock screen shows paused.

## Interruptions

Start playing, then:

| Steps | Expected |
|---|---|
| A call arrives (from a second phone); decline it | Audio stops when it rings; `suppression == .interruption`; after it ends, playback resumes by itself and `suppression` is `.none` |
| A call arrives; answer it, hang up | As above, resuming after the hang-up |
| Siri ("Hey Siri", ask the time) | Audio stops; resumes when Siri finishes |
| Another app starts audio (open Music or YouTube and play) | Audio stops; the app shows paused by another app. Stop the other app: without resume (`shouldResume` false) the player lands paused with `playWhenReady` false, and does not restart on its own |
| Same, but press pause in the app during the interruption, then end it | Nothing resumes |
| Pause first, then trigger a call | Nothing shows "paused by another app"; nothing resumes afterwards |
| Press play in the app while a call is still ringing | The player takes the session back and plays at once |

## Routes

| Steps | Expected |
|---|---|
| Play on wired or Lightning headphones; unplug | Paused (`playWhenReady` false), not playing on the speaker |
| Play on Bluetooth earbuds; turn them off or walk out of range | Paused, not on the speaker |
| Plug the headphones back in | Nothing starts by itself |
| Switch a Bluetooth headset between call and media profiles (join then leave a call on it) | Playback carries on; no pause from the profile switch |
| Unplug during an interruption, then end the interruption | Nothing resumes onto the speaker |

## Media-services reset

Settings, Developer, Reset Media Services is reported not to reproduce a real `mediaserverd` restart on
every iOS version: if the step does nothing, record that it did not reproduce rather than counting a pass.

| Steps | Expected |
|---|---|
| Play, trigger the reset | A short silence; then paused at the same position (within about a second), `recoveredPaused` sent, lock screen shows paused |
| Press play | Resumes from that position with the same item |
| Trigger the reset twice in a row, with a play between | Each lands paused; no stuck state |
| Trigger it during a phone call | Lands paused after the call; play works |

## Lock screen and Control Center

Lock the phone while playing item 1 of 3, then use the lock screen, and repeat the commands in Control
Center. Next and previous exist only with `skipMode: .tracks`, and the skip buttons only with
`.intervals`; run the rows for each mode your app uses.

| Steps | Expected |
|---|---|
| Play, pause | Audio follows at once; the icon and elapsed time stop and start |
| Next | Item 2 starts, with its title, artwork and duration; elapsed starts at 0 |
| Previous on item 2 | Item 1 starts. Previous on item 1 (no earlier item) restarts item 1 at 0, and the button stays enabled |
| Skip forward and back (with `skipMode: .intervals`) | Position moves by the configured seconds; the glyph shows those seconds; next and previous are not offered |
| Skip with `skipMode: .tracks` | Next and previous items; no interval buttons |
| Drag the scrubber | The audio follows the release point; elapsed lands there and keeps counting |
| Change the rate (with `supportedRates`) | Audio speeds up or slows with pitch kept; the lock screen's rate matches |
| Last item, repeat off | Next is greyed out. With repeat `.all` it wraps |
| Before the item has opened (just after a skip, on a slow stream) | Scrubbing and skips are off until the duration is known |

## Elapsed time stays in step

Compare the lock screen's elapsed time with the in-app position over 60 s after each step. They should
agree within a second and not drift.

| Steps | Expected |
|---|---|
| Seek forward 30 s in the app, then play | Lock screen jumps with the seek, then counts in step |
| Seek on the lock screen | The app's position jumps with it |
| Pause for 30 s, then play | Elapsed does not advance while paused, and continues from the pause point |
| Change the rate to 1.5x and back to 1x | The lock screen counts at the new rate and returns; no jump at either change |
| Seek while paused | Elapsed shows the new position while paused |
| Let item 1 end into item 2 (gapless) | Title and duration change at the join, elapsed restarts at 0, no gap |

## AirPlay

| Steps | Expected |
|---|---|
| Start playing on the phone, choose an AirPlay speaker | Audio moves to the speaker; playback continues without a restart |
| Play 5 minutes | The in-app position stays aligned with what is heard, with no drift |
| Seek, pause, change rate | Each takes effect on the speaker; elapsed follows |
| Turn the speaker off or leave the network | Paused (route lost), not playing on the phone speaker |
| Switch back to the phone | Playback is available again with `play()`, from the same position |
