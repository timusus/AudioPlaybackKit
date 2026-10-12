// swift-tools-version: 5.9
// The decode layer shared by Shuttle Podcasts and Shuttle2 on iOS: one dynamic FFmpeg for
// every app (ADR-0001, ADR-0006), the streaming decoder that drives it and the byte-source plumbing around it.
// Nothing here knows what a podcast, an ad or a queue is. See CLAUDE.md for build, test and release.
import PackageDescription

let package = Package(
    name: "AudioPlaybackKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // The pull decoder: a `StreamByteReader` in, interleaved Float32 PCM at the source's own
        // rate out, seekable and cancellable.
        .library(name: "PlaybackDecode", targets: ["PlaybackDecode"]),
        // Opt-in networking: the growing-file byte source (one ranged download per transaction, read
        // while it grows, retried across drops) and its file store. A consumer that only wants the
        // decoder links `PlaybackDecode` and gets none of it.
        .library(name: "PlaybackStreaming", targets: ["PlaybackStreaming"]),
        // A loopback `Range`-aware HTTP server with fault knobs, for a consumer's own tests of
        // anything built on `PlaybackStreaming`. No fixtures in it.
        .library(name: "PlaybackStreamingTestSupport", targets: ["PlaybackStreamingTestSupport"]),
        // Output over AVSampleBufferAudioRenderer: decoded PCM to the speaker, with an exact
        // position map, gapless joins and app-supplied processors (ADR-0018).
        .library(name: "PlaybackRender", targets: ["PlaybackRender"]),
        // `FakeAudioOutput`, `ManualPumpTimer`, `ManualExecutor` and `FakeItemSource`, to run a
        // `Transport` deterministically from a consumer's own tests.
        .library(name: "PlaybackRenderTestSupport", targets: ["PlaybackRenderTestSupport"]),
        // A main-actor `Player` over `Transport`: the item list, play intent and state, position
        // and duration in seconds, seek across items (ADR-0019).
        .library(name: "PlaybackPlayer", targets: ["PlaybackPlayer"]),
        // `FakeAudioSession`, `PlayerTestRig` and `FakeItemFactory`, to drive a `Player` deterministically
        // from a consumer's own tests.
        .library(name: "PlaybackPlayerTestSupport", targets: ["PlaybackPlayerTestSupport"]),
        // `NowPlayingSession`: a `Player` on the lock screen, Control Centre and CarPlay, and the
        // remote commands routed back to it. Kept apart so only an app that wants it links `MediaPlayer`.
        .library(name: "PlaybackNowPlaying", targets: ["PlaybackNowPlaying"]),
        // FFmpeg itself, for a consumer with its own C against libavformat. One FFmpeg per app:
        // a second copy would clash with this framework's symbols, or silently shadow them.
        .library(name: "FFmpeg", targets: ["CFFmpeg"]),
    ],
    targets: [
        // A dynamic framework the app embeds, so a user can relink against a modified FFmpeg
        // (LGPL-2.1 section 6, ADR-0001). It links its own system libraries. Committed, not
        // downloaded (CLAUDE.md); rebuild with `scripts/build-ffmpeg.sh`.
        .binaryTarget(name: "FFmpeg", path: "Frameworks/FFmpeg.xcframework"),
        // FFmpeg's headers and the `CFFmpeg` module. They sit outside the framework so
        // `<libavformat/avformat.h>` resolves as a plain include path, as FFmpeg's headers expect.
        .target(name: "CFFmpeg", dependencies: ["FFmpeg"]),
        .target(name: "CStreamDecode", dependencies: ["CFFmpeg"]),
        .target(name: "PlaybackDecode", dependencies: ["CStreamDecode"]),
        .target(name: "PlaybackStreaming", dependencies: ["PlaybackDecode"]),
        .target(name: "PlaybackStreamingTestSupport"),
        // Every rule lives in this Apple-free core, tested against a manual-clock fake output;
        // only the renderer adapter imports AVFoundation (ADR-0018).
        .target(name: "PlaybackRender", dependencies: ["PlaybackDecode"]),
        // The fake output, hand-fired pump and hand-run decode for an app's tests of anything built
        // on `Transport`, so none of them needs a real renderer or a wall clock (ADR-0018).
        .target(name: "PlaybackRenderTestSupport", dependencies: ["PlaybackRender"]),
        .testTarget(name: "PlaybackRenderTests", dependencies: ["PlaybackRender", "PlaybackRenderTestSupport"]),
        // Drives `Transport` through its public API only, so anything it needs is a render-layer change.
        .target(name: "PlaybackPlayer", dependencies: ["PlaybackRender"]),
        // The fake session and a rig that builds a `Player` on the fake output and manual clock, for
        // an app's tests of its own coordinator. Imports the player's SPI so an app's test need not (ADR-0019).
        .target(name: "PlaybackPlayerTestSupport", dependencies: ["PlaybackPlayer", "PlaybackRender", "PlaybackRenderTestSupport"]),
        .testTarget(
            name: "PlaybackPlayerTests",
            dependencies: ["PlaybackPlayer", "PlaybackPlayerTestSupport", "PlaybackRender", "PlaybackRenderTestSupport"]
        ),
        // Public imports only, as an app's own target has them: the example an app copies, and the
        // check that the product needs no `@testable` (ADR-0019).
        .testTarget(
            name: "PlaybackPlayerExternalConsumerTests",
            dependencies: ["PlaybackPlayer", "PlaybackPlayerTestSupport", "PlaybackRender", "PlaybackRenderTestSupport"]
        ),
        // The info and command centres sit behind internal seams the tests replace (ADR-0019).
        .target(name: "PlaybackNowPlaying", dependencies: ["PlaybackPlayer"]),
        .testTarget(
            name: "PlaybackNowPlayingTests",
            dependencies: ["PlaybackNowPlaying", "PlaybackPlayer", "PlaybackPlayerTestSupport", "PlaybackRender", "PlaybackRenderTestSupport"]
        ),
        // Two 20-45 s tone fixtures (under 250 KB each), served over the loopback server.
        .testTarget(
            name: "PlaybackStreamingTests",
            dependencies: ["PlaybackStreaming", "PlaybackStreamingTestSupport", "PlaybackDecode"],
            resources: [.copy("Fixtures")]
        ),
        // The fixtures are committed (three 20 s tones, well under 250 KB each): a decoder that
        // has to be handed a large real-world file before it can be tested is a decoder nobody tests.
        .testTarget(
            name: "PlaybackDecodeTests",
            dependencies: ["PlaybackDecode", "CStreamDecode"],
            resources: [.copy("Fixtures")]
        ),
        // Fault reader, fixture corpus and goldens for the decoder: every faulted decode must equal
        // the clean one. Fixtures and goldens are read by path (see Golden.swift), not as resources.
        .testTarget(name: "PlaybackDecodeConformanceTests", dependencies: ["PlaybackDecode"]),
    ]
)
