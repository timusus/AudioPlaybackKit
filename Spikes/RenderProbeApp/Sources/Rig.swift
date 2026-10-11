import AVFoundation
import CoreMedia

/// One audible ASBAR on a synchronizer, fed from a `Feeder`, with every notification and the pull
/// cadence logged. All feeding runs on one queue, so the counters need no lock.
final class Rig: @unchecked Sendable {
    enum Feed {
        /// Only what `requestMediaDataWhenReady` asks for.
        case whenReady
        /// Keep this many seconds of media queued ahead of the clock, ignoring `isReadyForMoreMediaData`.
        case depth(Double)
    }

    let renderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()
    let feeder: Feeder
    private let queue = DispatchQueue(label: "renderprobe.feed")
    private var observers: [NSObjectProtocol] = []
    private var feedTimer: DispatchSourceTimer?
    private var monitorTimer: DispatchSourceTimer?
    private var logEveryPull = false
    private var pulls = 0
    private var buffersThisSecond = 0
    private var aheadMin = Double.infinity
    private var aheadMax = -Double.infinity
    private var samples = 0

    init(_ feeder: Feeder, algorithm: AVAudioTimePitchAlgorithm? = nil) {
        self.feeder = feeder
        if let algorithm { renderer.audioTimePitchAlgorithm = algorithm }
        synchronizer.addRenderer(renderer)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer, queue: nil) { [weak self] note in
            guard let self else { return }
            let flush = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue.seconds
            Log.shared.write("AUTO-FLUSH at media \(flush.map { fmt($0) } ?? "?"); clock \(fmt(now)) rate \(synchronizer.rate) \(Session.outputs)")
            Events.shared.add("autoFlush", "flushTime=\(flush.map { fmt($0) } ?? "?") clock=\(fmt(now))")
            // Refill from where the renderer dropped the queue, or playback would stall.
            if let flush { queue.async { self.feeder.rewind(to: flush) } }
        })
        observers.append(center.addObserver(forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange, object: renderer, queue: nil) { [weak self] _ in
            Log.shared.write("renderer output configuration changed; clock \(fmt(self?.now ?? -1))")
            Events.shared.add("outputConfigurationChange", "clock=\(fmt(self?.now ?? -1)) hwRate=\(fmt(Session.shared.sampleRate, 0))")
        })
        observers.append(center.addObserver(forName: AVSampleBufferRenderSynchronizer.rateDidChangeNotification, object: synchronizer, queue: nil) { [weak self] _ in
            Log.shared.write("synchronizer rate -> \(self?.synchronizer.rate ?? -1) clock \(fmt(self?.now ?? -1))")
            Events.shared.add("rateChange", "rate=\(self?.synchronizer.rate ?? -1) clock=\(fmt(self?.now ?? -1))")
        })
    }

    var now: Double { synchronizer.currentTime().seconds }

    var state: String {
        let status = ["unknown", "rendering", "failed"][renderer.status.rawValue]
        let error = renderer.error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "none"
        return "status=\(status) error=\(error)"
    }

    /// Queues ahead, starts the clock, and logs the start latency stages.
    func start(_ feed: Feed, rate: Float = 1) async throws {
        logEveryPull = { if case .whenReady = feed { true } else { false } }()
        queue.async { self.beginFeeding(feed) }
        let begin = Log.shared.now
        while !renderer.hasSufficientMediaDataForReliablePlaybackStart, Log.shared.now - begin < 3 { try await pause(0.001) }
        Log.shared.write("sufficient media for start after \(fmt((Log.shared.now - begin) * 1000, 1)) ms, \(fmt(feeder.end)) s queued")
        let call = Log.shared.now
        let took = milliseconds { synchronizer.setRate(rate, time: .zero) }
        Log.shared.write("setRate(\(rate), 0) returned in \(fmt(took, 2)) ms")
        while now <= 0.0005, Log.shared.now - call < 10 { try await pause(0.002) }
        Log.shared.write("clock first advanced \(fmt((Log.shared.now - call) * 1000, 1)) ms after setRate; clock \(fmt(now, 4))")
        queue.async { self.beginMonitoring() }
    }

    /// Wall milliseconds `flush()` takes; the feed then restarts from the current clock.
    func flushAndRefill() -> Double {
        let took = milliseconds { renderer.flush() }
        queue.sync { feeder.rewind(to: now) }
        return took
    }

    func resume() {
        try? Session.shared.setActive(true)
        Log.shared.write("resume after interruption: rate=\(synchronizer.rate) \(state)")
        if synchronizer.rate == 0 { synchronizer.setRate(1, time: synchronizer.currentTime()) }
    }

    func stop() {
        queue.sync {
            feedTimer?.cancel()
            monitorTimer?.cancel()
            renderer.stopRequestingMediaData()
        }
        synchronizer.rate = 0
        renderer.flush()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func beginFeeding(_ feed: Feed) {
        switch feed {
        case .whenReady:
            renderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.pull() }
        case .depth(let target):
            feedTimer = repeating(every: 0.05) { [weak self] in self?.fill(to: target) }
        }
    }

    private func pull() {
        var count = 0
        while renderer.isReadyForMoreMediaData, let buffer = feeder.next() {
            renderer.enqueue(buffer)
            count += 1
        }
        pulls += 1
        buffersThisSecond += count
        if logEveryPull {
            Log.shared.write("pull: +\(count) buffers (\(fmt(Double(count) * 0.1, 1)) s), queued ahead \(fmt(feeder.end - now)) s, clock \(fmt(now))")
        }
    }

    private func fill(to target: Double) {
        var count = 0
        while feeder.end - now < target, let buffer = feeder.next() {
            renderer.enqueue(buffer)
            count += 1
        }
        if count > 0 {
            pulls += 1
            buffersThisSecond += count
        }
    }

    private func beginMonitoring() {
        monitorTimer = repeating(every: 0.1) { [weak self] in
            guard let self else { return }
            let ahead = feeder.end - now
            aheadMin = min(aheadMin, ahead)
            aheadMax = max(aheadMax, ahead)
            samples += 1
            guard samples == 10 else { return }
            Log.shared.write("1s: clock \(fmt(now)) ahead \(fmt(aheadMin))..\(fmt(aheadMax)) s, feeds \(pulls), buffers \(buffersThisSecond), \(state)")
            (samples, pulls, buffersThisSecond, aheadMin, aheadMax) = (0, 0, 0, .infinity, -.infinity)
        }
    }

    private func repeating(every interval: Double, _ body: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler(handler: body)
        timer.resume()
        return timer
    }
}
