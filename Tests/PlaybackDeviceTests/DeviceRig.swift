import AVFoundation
import MediaPlayer
import Observation
import PlaybackDecode
import UIKit
import XCTest
@testable import PlaybackNowPlaying
@_spi(Testing) @testable import PlaybackPlayer
@_spi(Testing) @testable import PlaybackRender

/// The three items, in list order: 4 s, 8 s and 10 s.
enum Fixture {
    static let items = ["flac_stereo.flac", "cbr_info_64k.mp3", "cbr_32k_dense_reservoir.mp3"]

    static func url(_ item: String) -> URL {
        Bundle(for: TappedOutput.self).url(forResource: item, withExtension: nil)!
    }
}

/// An app's policy over the player, as Shuttle2's `SessionPlayer`: everything else forwards.
@MainActor @Observable
final class PolicyPlayer: ForwardingNowPlayingControllable {
    typealias Item = String

    @ObservationIgnored let player: Player<String>
    var removed: PlayerCommands = []
    /// For every item without its own in `itemIntervals`; nil for next and previous.
    var intervals: SkipIntervals?
    var itemIntervals: [String: SkipIntervals] = [:]

    init(_ player: Player<String>, intervals: SkipIntervals? = nil) {
        self.player = player
        self.intervals = intervals
    }

    var availableCommands: PlayerCommands { player.availableCommands.subtracting(removed) }

    var skipIntervals: SkipIntervals? { player.currentItem.flatMap { itemIntervals[$0] } ?? intervals }
}

/// The production output with a tap on what reaches the renderer, so a test can tell real audio from
/// silence and read the synchronizer's clock.
final class TappedOutput: AudioOutput, @unchecked Sendable {
    let base = SampleBufferAudioOutput()
    private let lock = NSLock()
    private var frames = 0
    private var peak: Float = 0

    /// Frames enqueued so far, and the loudest sample among them since the last call.
    func takeTap() -> (frames: Int, peak: Float) {
        lock.withLock {
            defer { peak = 0 }
            return (frames, peak)
        }
    }

    func enqueue(_ samples: [Float], format: PCMFormat, at time: TimeInterval) throws {
        let loudest = samples.reduce(Float(0)) { max($0, abs($1)) }
        lock.withLock {
            frames += samples.count / format.channelCount
            peak = max(peak, loudest)
        }
        try base.enqueue(samples, format: format, at: time)
    }

    func flush() { base.flush() }
    func setRate(_ rate: Double, at time: TimeInterval?) { base.setRate(rate, at: time) }
    func setVolume(_ volume: Float) { base.setVolume(volume) }
    func currentTime() -> TimeInterval { base.currentTime() }
    var outputLatency: TimeInterval { base.outputLatency }
    var isReadyForMoreData: Bool { base.isReadyForMoreData }
    func rebuild() throws { try base.rebuild() }
    func setEventHandler(_ handler: @escaping @Sendable (AudioOutputEvent) -> Void) { base.setEventHandler(handler) }
}

/// Holds an item's `open()` until `openGate()`, so the moment before the duration is known lasts as
/// long as a test needs instead of the few milliseconds a local file takes.
final class GatedSource: ItemSource, @unchecked Sendable {
    private let base: FFmpegItemSource
    private let gate = DispatchSemaphore(value: 0)

    init(_ base: FFmpegItemSource) {
        self.base = base
    }

    func openGate() { gate.signal() }

    func begin(epoch: UInt64) { base.begin(epoch: epoch) }
    func open() throws -> PCMFormat {
        // Bounded, so a test that fails before releasing it cannot hang the decode queue.
        _ = gate.wait(timeout: .now() + 10)
        return try base.open()
    }
    var duration: Int64? { base.duration }
    var isSeekable: Bool { base.isSeekable }
    func seek(toFrame frame: Int64) throws -> Int64 { try base.seek(toFrame: frame) }
    func nextChunk() throws -> [Float]? { try base.nextChunk() }
    func interrupt(through epoch: UInt64) { base.interrupt(through: epoch) }
    func release() { base.release() }
}

/// Hides the file's duration but still seeks, as a server transcode that re-opens at a time offset.
final class UnknownLengthSource: ItemSource, @unchecked Sendable {
    private let base: FFmpegItemSource

    init(_ base: FFmpegItemSource) {
        self.base = base
    }

    var isSeekable: Bool { true }
    func begin(epoch: UInt64) { base.begin(epoch: epoch) }
    func open() throws -> PCMFormat { try base.open() }
    func seek(toFrame frame: Int64) throws -> Int64 { try base.seek(toFrame: frame) }
    func nextChunk() throws -> [Float]? { try base.nextChunk() }
    func interrupt(through epoch: UInt64) { base.interrupt(through: epoch) }
    func release() { base.release() }
}

/// A `Player` built as `Player(makeSource:audioSession:)` builds it, on `SystemAudioSession` and the
/// renderer, shown by a `NowPlayingSession` on the shared info and command centres.
@MainActor
final class DeviceRig {
    let output = TappedOutput()
    let player: Player<String>
    private let commands = SystemRemoteCommandCenter()
    let infoCenter = StampedInfoCenter()
    private(set) var nowPlaying: NowPlayingSession<String>!
    private(set) var events: [PlayerEvent<String>] = []
    /// Items whose next source waits for `GatedSource.openGate()`.
    var gated: Set<String> = []
    private(set) var gates: [GatedSource] = []
    /// Items whose source is an `UnknownLengthSource`.
    var unknownLength: Set<String> = []
    private var eventTask: Task<Void, Never>?

    /// `wrap` puts an app's wrapper between the session and the player.
    init(supportedRates: [Double] = [1, 1.5, 2], wrap: (Player<String>) -> any NowPlayingControllable<String> = { $0 }) {
        weak var weakSelf: DeviceRig?
        let output = output
        player = Player(
            makeSource: { item in
                let source = try FFmpegItemSource(reader: FileByteReader(url: Fixture.url(item)))
                if weakSelf?.unknownLength.contains(item) == true { return UnknownLengthSource(source) }
                guard let rig = weakSelf, rig.gated.contains(item) else { return source }
                let gate = GatedSource(source)
                rig.gates.append(gate)
                return gate
            },
            session: SystemAudioSession(configuration: .longFormAudio)
        ) { onEvent in
            Transport(output: output, timer: DispatchPumpTimer(), executor: SerialQueueExecutor(), onEvent: onEvent)
        }
        weakSelf = self
        // The public init's real centres, held here so `send` reaches the targets and writes are timed.
        nowPlaying = NowPlayingSession(
            player: wrap(player), supportedRates: supportedRates,
            metadata: { NowPlayingMetadata(title: $0) }, artwork: nil,
            infoCenter: infoCenter, commandCenter: commands
        )
        let stream = player.events
        eventTask = Task { [weak self] in
            for await event in stream { self?.events.append(event) }
        }
    }

    /// Leaves the shared centres and the session as a fresh rig finds them.
    func tearDown() async {
        nowPlaying.release()
        gates.forEach { $0.openGate() }
        player.removeAll()
        eventTask?.cancel()
        // The deactivation runs on the session's queue; the next test's activation queues behind it.
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// Starts `items[index]` at `position` and waits until it is heard.
    func startPlaying(at index: Int = 0, position: TimeInterval = 0, file: StaticString = #filePath, line: UInt = #line) async {
        player.setItems(Fixture.items, startIndex: index, startPosition: position)
        player.play()
        await waitUntil("playing", file: file, line: line) { self.player.isPlaying && self.player.position > position + 0.1 }
    }

    /// Polls on the main actor, so the player's drains and the session's refreshes run meanwhile.
    func waitUntil(
        _ what: String, timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what); \(state)", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// What a timeout reports, so a failure on the phone says which layer stopped.
    private var state: String {
        let renderer = output.base.renderer
        return "player \(player.state) playWhenReady \(player.playWhenReady) suppression \(player.suppression) "
            + "item \(player.currentIndex.map(String.init) ?? "nil") position \(player.position) error \(player.error.map { "\($0)" } ?? "nil"); "
            + "renderer status \(renderer.status.rawValue) error \(renderer.error.map { "\($0)" } ?? "nil") clock \(output.currentTime()); "
            + "session \(AVAudioSession.sharedInstance().category.rawValue) other audio \(AVAudioSession.sharedInstance().isOtherAudioPlaying); "
            + "app state \(UIApplication.shared.applicationState.rawValue)"
    }

    func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func didSend(_ match: (PlayerEvent<String>) -> Bool) -> Bool {
        events.contains(where: match)
    }

    // MARK: Audible

    /// Over `seconds`, the renderer is rendering, the synchronizer's clock runs at the player's rate,
    /// and what reaches the renderer is the fixture's audio, not silence.
    func assertAudible(over seconds: TimeInterval = 1, file: StaticString = #filePath, line: UInt = #line) async {
        let renderer = output.base.renderer
        XCTAssertEqual(renderer.status, .rendering, "renderer status", file: file, line: line)
        XCTAssertNil(renderer.error, file: file, line: line)
        XCTAssertEqual(renderer.volume, 1, file: file, line: line)
        XCTAssertTrue(player.isPlaying, "isPlaying", file: file, line: line)
        // `isPlaying` is true from the play, but on an iPhone the restarted clock started up to 0.36 s
        // later after a seek or a fresh renderer, and the old one ran on until the restart, so it is
        // timed from when what is heard moves.
        let held = player.position
        await waitUntil("position moving", timeout: 1, file: file, line: line) { player.position > held }
        let start = (clock: output.currentTime(), wall: Date(), tap: output.takeTap())
        await sleep(seconds)
        let advanced = output.currentTime() - start.clock
        let wall = Date().timeIntervalSince(start.wall)
        let tap = output.takeTap()
        XCTAssertEqual(advanced, wall * player.rate, accuracy: 0.15 * player.rate, "output clock against wall time", file: file, line: line)
        XCTAssertGreaterThan(tap.frames, start.tap.frames, "frames keep reaching the renderer", file: file, line: line)
        XCTAssertGreaterThan(tap.peak, 0.05, "what reaches the renderer is not silence", file: file, line: line)
    }

    /// The synchronizer's clock stands still, so nothing queued is played, and the position holds.
    func assertSilent(over seconds: TimeInterval = 0.5, file: StaticString = #filePath, line: UInt = #line) async {
        // The transport reports the position every 100 ms, the last one after the pause lands.
        await sleep(0.25)
        let start = (clock: output.currentTime(), position: player.position)
        await sleep(seconds)
        XCTAssertFalse(player.isPlaying, "isPlaying", file: file, line: line)
        XCTAssertEqual(output.currentTime(), start.clock, accuracy: 0.01, "output clock while silent", file: file, line: line)
        XCTAssertEqual(player.position, start.position, accuracy: 0.01, "position while silent", file: file, line: line)
    }

    // MARK: Now Playing

    var info: [String: Any] { MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:] }
    var shownTitle: String? { info[MPMediaItemPropertyTitle] as? String }
    var shownDuration: Double? { (info[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue }
    var shownElapsed: Double? { (info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue }
    var shownRate: Double? { (info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue }
    var shownState: MPNowPlayingPlaybackState { MPNowPlayingInfoCenter.default().playbackState }

    /// Lets the session's refresh task run after a player change.
    func settle() async {
        await nowPlaying.pendingRefresh?.value
        await Task.yield()
    }

    // MARK: Remote commands

    /// Runs what the command's registered target runs for the system's event, or nil when the
    /// command is disabled and the system would send nothing. Only after checking the real centre's
    /// `isEnabled` agrees, since that is what the lock screen reads.
    @discardableResult
    func send(_ command: RemoteCommand, _ event: RemoteCommandEvent = .plain, file: StaticString = #filePath, line: UInt = #line) -> MPRemoteCommandHandlerStatus? {
        let status = commands.send(command, event)
        XCTAssertEqual(remote(command).isEnabled, status != nil, "\(command) isEnabled against its handler", file: file, line: line)
        return status
    }

    func remote(_ command: RemoteCommand) -> MPRemoteCommand {
        let center = MPRemoteCommandCenter.shared()
        return switch command {
        case .play: center.playCommand
        case .pause: center.pauseCommand
        case .togglePlayPause: center.togglePlayPauseCommand
        case .nextTrack: center.nextTrackCommand
        case .previousTrack: center.previousTrackCommand
        case .skipForward: center.skipForwardCommand
        case .skipBackward: center.skipBackwardCommand
        case .changePlaybackPosition: center.changePlaybackPositionCommand
        case .changePlaybackRate: center.changePlaybackRateCommand
        }
    }
}

/// Writes through to `MPNowPlayingInfoCenter.default()` and notes when, since the system
/// extrapolates elapsed time from the moment of the write.
@MainActor
final class StampedInfoCenter: NowPlayingInfoCenter {
    private let center = MPNowPlayingInfoCenter.default()
    private(set) var lastWrite = Date()

    var nowPlayingInfo: [String: Any]? {
        get { center.nowPlayingInfo }
        set {
            center.nowPlayingInfo = newValue
            lastWrite = Date()
        }
    }

    var playbackState: MPNowPlayingPlaybackState {
        get { center.playbackState }
        set { center.playbackState = newValue }
    }
}

// MARK: System notifications

/// The notifications `AVAudioSession` posts, with the userInfo iOS sends and the shared session as
/// object. Only the session posts them, so the test stands in for it.
@MainActor
enum SystemSession {
    static func interruptionBegan() {
        post(AVAudioSession.interruptionNotification, [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            AVAudioSessionInterruptionReasonKey: AVAudioSession.InterruptionReason.default.rawValue,
        ])
    }

    static func interruptionEnded(shouldResume: Bool) {
        let options: AVAudioSession.InterruptionOptions = shouldResume ? .shouldResume : []
        post(AVAudioSession.interruptionNotification, [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: options.rawValue,
        ])
    }

    /// `previous` is the route before the change; the current one is the device's real route.
    static func routeChanged(_ reason: AVAudioSession.RouteChangeReason, previous: [AVAudioSession.Port]) {
        post(AVAudioSession.routeChangeNotification, [
            AVAudioSessionRouteChangeReasonKey: reason.rawValue,
            AVAudioSessionRouteChangePreviousRouteKey: StubRoute(previous),
        ])
    }

    static func mediaServicesWereReset() {
        post(AVAudioSession.mediaServicesWereResetNotification, nil)
    }

    private static func post(_ name: Notification.Name, _ userInfo: [AnyHashable: Any]?) {
        NotificationCenter.default.post(name: name, object: AVAudioSession.sharedInstance(), userInfo: userInfo)
    }
}

/// A route of the given outputs: the classes have no public initialiser that sets them, and a
/// device's real route has no headphones to lose.
private final class StubRoute: AVAudioSessionRouteDescription, @unchecked Sendable {
    private let ports: [AVAudioSessionPortDescription]

    init(_ ports: [AVAudioSession.Port]) {
        self.ports = ports.map(StubPort.init)
        super.init()
    }

    override var outputs: [AVAudioSessionPortDescription] { ports }
    override var inputs: [AVAudioSessionPortDescription] { [] }
}

private final class StubPort: AVAudioSessionPortDescription, @unchecked Sendable {
    private let port: AVAudioSession.Port

    init(_ port: AVAudioSession.Port) {
        self.port = port
        super.init()
    }

    override var portType: AVAudioSession.Port { port }
    override var portName: String { port.rawValue }
    override var uid: String { port.rawValue }
}

/// A base class whose tests share the global session and centres, so each gets a fresh rig and
/// leaves them released.
@MainActor
class DeviceTestCase: XCTestCase {
    private(set) var rig: DeviceRig!

    /// Replaces the rig with one whose session drives a `PolicyPlayer` over the player.
    @discardableResult
    func makePolicyRig(intervals: SkipIntervals? = nil) async -> PolicyPlayer {
        await rig?.tearDown()
        var policy: PolicyPlayer!
        rig = DeviceRig {
            policy = PolicyPlayer($0, intervals: intervals)
            return policy
        }
        return policy
    }

    override func setUp() async throws {
        rig = DeviceRig()
    }

    override func tearDown() async throws {
        await rig?.tearDown()
        rig = nil
    }
}
