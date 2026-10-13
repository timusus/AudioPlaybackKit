# Lock screen and remote commands

Code: [`NowPlayingRecipe.swift`](../../Tests/RecipesTests/NowPlayingRecipe.swift). Link
`PlaybackNowPlaying`; tests also link `PlaybackNowPlayingTestSupport`.

`NowPlayingSession` publishes a `Player` to Now Playing, Control Centre and CarPlay and routes the
remote commands back to it. There is one per app (both centres are global); keep it for the app's life.

```swift
let session = NowPlayingSession(
    player: player,
    metadata: { NowPlayingMetadata(title: "Track \($0.id)", artist: "Artist") }
)
```

The test builds the same session over fake centres, with `now` as its clock:

```swift
let session = NowPlayingSession(
    player: rig.player,
    metadata: { NowPlayingMetadata(title: "Track \($0.id)", artist: "Artist") },
    infoCenter: info,
    commandCenter: commands,
    now: { wall }
)
```

Read what the lock screen shows, and press buttons as the system would:

```swift
XCTAssertEqual(info[MPMediaItemPropertyTitle], "Track 1")
XCTAssertEqual(info.playbackState, .playing)
// A command is enabled only while the player can do it.
XCTAssertTrue(commands.enabled.isSuperset(of: [.play, .pause, .nextTrack]))

XCTAssertEqual(commands.press(.changePlaybackPosition, .position(6)), .success)
XCTAssertEqual(commands.press(.nextTrack), .success)
XCTAssertEqual(commands.press(.pause), .success)
```

After a change, `await session.settle()` before reading the fakes: the session refreshes on a later
main-actor turn. `session.release()` disables every command and clears the info, for when the player
goes away.

Pass `artwork:` (async, once per item change) and `supportedRates:` to the initialiser for cover art and
the rate command. The app still needs `audio` in `UIBackgroundModes`.
