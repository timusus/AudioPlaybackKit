# Recipes

Task-first examples. Each page quotes code from [`Tests/RecipesTests`](../../Tests/RecipesTests), which
compiles and runs offline on every test run (a WAV generated in code, fakes, `LoopbackMediaServer`), so
none of it can rot. [Usage](../usage.md) is the reference; these are the shortest path to a working app.

| I want to | Recipe |
|---|---|
| Decode or play a local file | [Play a file](play-a-file.md) |
| Play a URL while it downloads, and survive a dropped connection | [Stream a URL](stream-a-url.md) |
| Play a queue gaplessly, seek, and show progress | [Queue, seek and progress](queue-and-seek.md) |
| Show the lock screen and answer remote commands | [Lock screen](lock-screen.md) |
| Decide between retry and skip when an item fails | [Handle errors](handle-errors.md) |
| Test my own playback code without audio | [Test your code](test-your-code.md) |
| Write an effect (gain, downmix, meter, silence trimmer) | [Audio processors](audio-processors.md) |

**AirPlay** needs no code: output is an `AVSampleBufferAudioRenderer`, so AirPlay 2 works once the app
lists `audio` in `UIBackgroundModes` and shows an `AVRoutePickerView`. See
[AirPlay](../usage.md#airplay).

The example processors are examples to copy, not API: effects stay in the app.
