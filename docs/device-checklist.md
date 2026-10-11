# Device checklist

The real `AVAudioSession`, `MPRemoteCommandCenter`, routes and AirPlay. Most rows run as
`Tests/PlaybackDeviceTests` through `scripts/device-test.sh` on an iPhone; the "Covered by" column names
the test. Rows marked manual need hardware or a person; run them on an iPhone before relying on a
release, with a build that plays a list of at least three items (an album or a few episodes) through
`Player` and `NowPlayingSession`. Record what passed and failed in the release's tracking issue; fix
this list when a step is wrong or a case is missing.

"Playing" means the audio is audible and `isPlaying` is true. "Paused" means silent, `playWhenReady` is
false, and the lock screen shows paused.

## Interruptions

Start playing, then:

| Steps | Expected | Covered by |
|---|---|---|
| A call arrives (from a second phone); decline it | Audio stops when it rings; `suppression == .interruption`; after it ends, playback resumes by itself and `suppression` is `.none` | Manual: declining needs a second phone; `testInterruptionEndingWithShouldResumeResumes` posts the same notifications |
| A call arrives; answer it, hang up | As above, resuming after the hang-up | `RealCallTests.testCallInterruptsAndPlaybackResumesWhenItEnds` |
| Siri ("Hey Siri", ask the time); depends on whether iOS sends `.shouldResume` when Siri ends, so note which you saw | With `.shouldResume`: audio stops, then resumes when Siri finishes. Without it: audio stops and the player lands paused with `playWhenReady` false, and does not restart on its own | Manual |
| Interruption that ends with `.shouldResume`: FaceTime or phone call from a second phone, ended from the other side (or declined) | Audio stops; `suppression == .interruption`; after it ends, playback resumes by itself and `suppression` is `.none` | `SessionNotificationTests.testInterruptionEndingWithShouldResumeResumes` |
| Interruption that ends without `.shouldResume`: open Music or YouTube and start playback, then pause or stop it there | Audio stops; the app shows paused by another app; the player lands paused with `playWhenReady` false and does not restart on its own | `RealCallTests.testNonMixablePlaybackInterruptsAndNothingResumes`, `SessionNotificationTests.testInterruptionEndingWithoutShouldResumeLandsPaused` |
| Same, but press pause in the app during the interruption, then end it | Nothing resumes | `SessionNotificationTests.testPauseDuringInterruptionResumesNothing` |
| Pause first, then trigger a call | Nothing shows "paused by another app"; nothing resumes afterwards | `SessionNotificationTests.testPauseBeforeInterruptionShowsNoSuppressionAndResumesNothing` |
| Press play in the app while a call is still ringing | The player takes the session back and plays at once | `SessionNotificationTests.testPlayWhileInterruptedTakesTheSessionBack` |

## Routes

| Steps | Expected | Covered by |
|---|---|---|
| Play on wired or Lightning headphones; unplug | Paused (`playWhenReady` false), not playing on the speaker | Manual; `SessionNotificationTests.testLosingHeadphonesPausesAndNothingStartsWhenTheyReturn` posts the notification |
| Play on Bluetooth earbuds; turn them off or walk out of range | Paused, not on the speaker | Manual; `SessionNotificationTests.testLosingBluetoothPauses` posts the notification |
| Plug the headphones back in | Nothing starts by itself | Manual; `SessionNotificationTests.testLosingHeadphonesPausesAndNothingStartsWhenTheyReturn` posts the notification |
| Switch a Bluetooth headset between call and media profiles (join then leave a call on it) | Playback carries on; no pause from the profile switch | Manual; `SessionNotificationTests.testCategoryChangeAndNewDeviceDoNotPause` posts the notifications |
| Unplug during an interruption, then end the interruption | Nothing resumes onto the speaker | `SessionNotificationTests.testRouteLossDuringInterruptionResumesNothing` (posted); the real unplug is manual |

## Media-services reset

Settings, Developer, Reset Media Services is reported not to reproduce a real `mediaserverd` restart on
every iOS version: if the step does nothing, record that it did not reproduce rather than counting a pass.

| Steps | Expected | Covered by |
|---|---|---|
| Play, trigger the reset | A short silence; then paused at the same position (within about a second), `recoveredPaused` sent, lock screen shows paused | `SessionNotificationTests.testResetLandsPausedAtThePositionAndPlayResumesFromIt` (posted); the Settings reset is manual |
| Press play | Resumes from that position with the same item | `SessionNotificationTests.testResetLandsPausedAtThePositionAndPlayResumesFromIt` |
| Trigger the reset twice in a row, with a play between | Each lands paused; no stuck state | `SessionNotificationTests.testTwoResetsWithAPlayBetweenEachLandPaused` |
| Trigger it during a phone call | Lands paused after the call; play works | `SessionNotificationTests.testResetDuringInterruptionLandsPausedAndPlayWorks` |

## Lock screen and Control Center

Lock the phone while playing item 1 of 3, then use the lock screen, and repeat the commands in Control
Center. Next and previous exist only with `skipMode: .tracks`, and the skip buttons only with
`.intervals`; run the rows for each mode your app uses.

| Steps | Expected | Covered by |
|---|---|---|
| Play, pause | Audio follows at once; the icon and elapsed time stop and start | `RemoteCommandTests.testPlayPauseAndToggle` |
| Next | Item 2 starts, with its title, artwork and duration; elapsed starts at 0 | `RemoteCommandTests.testTrackSkipsMoveBetweenItemsAndPreviousOnTheFirstRestartsIt` |
| Previous on item 2 | Item 1 starts. Previous on item 1 (no earlier item) restarts item 1 at 0, and the button stays enabled | `RemoteCommandTests.testTrackSkipsMoveBetweenItemsAndPreviousOnTheFirstRestartsIt` |
| Skip forward and back (with `skipMode: .intervals`) | Position moves by the configured seconds; the glyph shows those seconds; next and previous are not offered | `RemoteCommandTests.testIntervalSkipsMoveByTheConfiguredSeconds` |
| Skip with `skipMode: .tracks` | Next and previous items; no interval buttons | `RemoteCommandTests.testTrackSkipsMoveBetweenItemsAndPreviousOnTheFirstRestartsIt` |
| Drag the scrubber | The audio follows the release point; elapsed lands there and keeps counting | `RemoteCommandTests.testScrubberSeeksAndElapsedKeepsCounting` |
| Change the rate (with `supportedRates`) | Audio speeds up or slows with pitch kept; the lock screen's rate matches | `RemoteCommandTests.testRateCommandChangesTheHeardRateAndTheShownOne` |
| Last item, repeat off | Next is greyed out. With repeat `.all` it wraps | `RemoteCommandTests.testNextOnTheLastItemIsOffWithRepeatOffAndWrapsWithRepeatAll` |
| Before the item has opened (just after a skip, on a slow stream) | Scrubbing and skips are off until the duration is known | `RemoteCommandTests.testScrubbingAndSkipsAreOffUntilTheDurationIsKnown` |

## Elapsed time stays in step

Compare the lock screen's elapsed time with the in-app position over 60 s after each step. They should
agree within a second and not drift.

| Steps | Expected | Covered by |
|---|---|---|
| Seek forward 30 s in the app, then play | Lock screen jumps with the seek, then counts in step | `ElapsedTimeTests.testSeekInTheApp` |
| Seek on the lock screen | The app's position jumps with it | `ElapsedTimeTests.testSeekOnTheLockScreen` |
| Pause for 30 s, then play | Elapsed does not advance while paused, and continues from the pause point | `ElapsedTimeTests.testPauseThenPlay` |
| Change the rate to 1.5x and back to 1x | The lock screen counts at the new rate and returns; no jump at either change | `ElapsedTimeTests.testRateUpAndBack` |
| Seek while paused | Elapsed shows the new position while paused | `ElapsedTimeTests.testSeekWhilePaused` |
| Let item 1 end into item 2 (gapless) | Title and duration change at the join, elapsed restarts at 0, no gap | `ElapsedTimeTests.testGaplessJoin` |

## AirPlay

| Steps | Expected | Covered by |
|---|---|---|
| Start playing on the phone, choose an AirPlay speaker | Audio moves to the speaker; playback continues without a restart | Manual |
| Play 5 minutes | The in-app position stays aligned with what is heard, with no drift | Manual |
| Seek, pause, change rate | Each takes effect on the speaker; elapsed follows | Manual |
| Turn the speaker off or leave the network | Paused (route lost), not playing on the phone speaker | Manual |
| Switch back to the phone | Playback is available again with `play()`, from the same position | Manual |
