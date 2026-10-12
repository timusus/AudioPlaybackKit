import Foundation
import PlaybackRender
import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// Seeded random sequences of edits, seeks, repeat changes, pause at end, clock steps and failing
/// items, run through `Player` on the fake output and through `PlayerModel`, compared after every
/// operation. A mismatch reports the seed and the shortest failing sequence the shrinker found.
/// `PLAYER_MODEL_SOAK=<n>` runs n more seeds.
@MainActor
final class PlayerModelBasedTests: XCTestCase {
    /// Short items so ends, repeats and edits near an end come often; x fails to make its source
    /// and y fails to open, so neither has a length the model can play.
    private static let lengths: [String: TimeInterval] = ["a": 4, "b": 5, "c": 4.5, "d": 6]
    private static let names = ["a", "b", "c", "d", "x", "y"]
    private static let fixedSeeds: Range<UInt64> = 0..<150
    private static let operationsPerSequence = 40

    func testPlayerMatchesTheModel() {
        let soak = ProcessInfo.processInfo.environment["PLAYER_MODEL_SOAK"].flatMap(UInt64.init) ?? 0
        let seeds = Self.fixedSeeds.lowerBound..<(Self.fixedSeeds.upperBound + soak)
        for seed in seeds {
            let operations = Self.generate(seed: seed)
            guard let mismatch = Self.run(operations) else { continue }
            let shrunk = Self.shrink(operations)
            let report = Self.run(shrunk) ?? mismatch
            XCTFail("""
            Player diverged from the model, seed \(seed). Shrunk to \(shrunk.count) of \(operations.count) operations:
            \(shrunk.map { "  \($0)" }.joined(separator: "\n"))
            \(report)
            """)
            return
        }
    }

    // media3 flushes a next it already read when a repeat change or an edit means another follows
    // (`MediaPeriodQueue.updateRepeatMode`, `updateQueuedPeriods`), and so does the player.
    func testAChangeToWhatFollowsAfterDecodePassedTheJoinIsHonoured() {
        let repeatChange: [Operation] = [.setItems(["a", "b"], startIndex: 0, startPosition: 0), .play, .advance(quarters: 12), .repeatMode(.one), .advance(quarters: 8)]
        XCTAssertNil(Self.run(repeatChange))

        let insert: [Operation] = [.setItems(["a", "b"], startIndex: 0, startPosition: 0), .play, .advance(quarters: 12), .insert(["c"], at: 1), .advance(quarters: 8)]
        XCTAssertNil(Self.run(insert))

        // Seconds from the join again after the seek, with b already decoded before it.
        let seekBack: [Operation] = [.setItems(["a", "b"], startIndex: 0, startPosition: 0), .play, .advance(quarters: 12), .seek(0), .insert(["c"], at: 1), .advance(quarters: 20)]
        XCTAssertNil(Self.run(seekBack))
    }

    // MARK: Operations

    enum Operation: CustomStringConvertible {
        case setItems([String], startIndex: Int, startPosition: TimeInterval)
        case insert([String], at: Int)
        case move(from: Int, to: Int)
        case remove(at: Int)
        case removeAll
        case play, pause, stop
        case seek(TimeInterval)
        case seekItem(TimeInterval, index: Int)
        case skipToNext, skipToPrevious
        case repeatMode(RepeatMode)
        case pauseAtEndOfItem(Bool)
        case advance(quarters: Int)

        var description: String {
            switch self {
            case let .setItems(items, start, position): "setItems(\(items), startIndex: \(start), startPosition: \(position))"
            case let .insert(items, index): "insert(\(items), at: \(index))"
            case let .move(from, to): "move(from: \(from), to: \(to))"
            case let .remove(index): "remove(at: \(index))"
            case .removeAll: "removeAll()"
            case .play: "play()"
            case .pause: "pause()"
            case .stop: "stop()"
            case let .seek(position): "seek(to: \(position))"
            case let .seekItem(position, index): "seek(to: \(position), itemAt: \(index))"
            case .skipToNext: "skipToNext()"
            case .skipToPrevious: "skipToPrevious()"
            case let .repeatMode(mode): "repeatMode = .\(mode)"
            case let .pauseAtEndOfItem(value): "pauseAtEndOfItem = \(value)"
            case let .advance(quarters): "advance(\(Double(quarters) / 4) s)"
            }
        }

        /// Whether the indices fit the list; a shrunk sequence may leave an operation out of range.
        func isValid(count: Int) -> Bool {
            switch self {
            case let .setItems(items, start, _): items.indices.contains(start)
            case let .insert(_, index): (0...count).contains(index)
            case let .move(from, to): (0..<count).contains(from) && (0..<count).contains(to)
            case let .remove(index): (0..<count).contains(index)
            case let .seekItem(_, index): (0..<count).contains(index)
            default: true
            }
        }
    }

    /// Item lists and indices are drawn against the model's list as it stands at each step.
    static func generate(seed: UInt64) -> [Operation] {
        var random = SplitMix64(seed: seed)
        var model = PlayerModel(lengths: lengths)
        var operations: [Operation] = []
        func someItems(_ random: inout SplitMix64, max: Int) -> [String] {
            (0..<random.int(in: 1...max)).map { _ in
                // Failing items one draw in six, so most sequences get some way before one.
                random.int(in: 0..<6) == 0 ? names[random.int(in: 4...5)] : names[random.int(in: 0...3)]
            }
        }
        // Seeks land on the quarter seconds the clock moves in, at times before 0, never at an item's
        // end: whether a paused seek to the end crosses into the next depends on decode, not on rules.
        func somePosition(_ random: inout SplitMix64) -> TimeInterval {
            Double(random.int(in: -2...7)) / 4
        }
        while operations.count < operationsPerSequence {
            let count = model.items.count
            let operation: Operation
            switch random.int(in: 0..<100) {
            case 0..<6:
                let items = someItems(&random, max: 4)
                operation = .setItems(items, startIndex: random.int(in: 0..<items.count), startPosition: Double(random.int(in: 0...4)) / 4)
            case 6..<14:
                operation = .insert(someItems(&random, max: 2), at: random.int(in: 0...count))
            case 14..<19 where count > 0:
                operation = .move(from: random.int(in: 0..<count), to: random.int(in: 0..<count))
            case 19..<25 where count > 0:
                operation = .remove(at: random.int(in: 0..<count))
            case 25..<26:
                operation = .removeAll
            case 26..<36:
                operation = .play
            case 36..<40:
                operation = .pause
            case 40..<42:
                operation = .stop
            case 42..<48:
                operation = .seek(somePosition(&random))
            case 48..<53 where count > 0:
                operation = .seekItem(somePosition(&random), index: random.int(in: 0..<count))
            case 53..<56:
                operation = .skipToNext
            case 56..<58:
                operation = .skipToPrevious
            case 58..<62:
                operation = .repeatMode([.off, .all, .one][random.int(in: 0...2)])
            case 62..<65:
                operation = .pauseAtEndOfItem(random.int(in: 0...1) == 1)
            default:
                operation = .advance(quarters: random.int(in: 1...16))
            }
            apply(operation, to: &model)
            operations.append(operation)
        }
        return operations
    }

    // MARK: Running

    /// Runs `operations` through a fresh player and model; nil if they agreed throughout.
    static func run(_ operations: [Operation]) -> String? {
        let rig = PlayerRig()
        for (name, length) in lengths { rig.factory.lengths[name] = Int64(length * 8) }
        rig.factory.lengths["y"] = 16
        rig.factory.failing = ["x"]
        rig.factory.unopenable = ["y"]
        let player = rig.player!
        var sent: [PlayerModel.Event] = []
        player.onEvent = { event in
            switch event {
            case let .itemTransition(from, to, reason): sent.append(.transition(from: from, to: to, reason: reason))
            case let .itemFailed(index, _): sent.append(.failed(index: index))
            case .playWhenReadyChanged(false, .endOfItem): sent.append(.pausedAtEndOfItem)
            default: break
            }
        }
        var model = PlayerModel(lengths: lengths)
        for (step, operation) in operations.enumerated() {
            // A shrunk sequence may bring an index out of range.
            guard operation.isValid(count: model.items.count) else { continue }
            apply(operation, to: &model)
            apply(operation, to: player, rig: rig)
            let expected = model.snapshot
            let actual = snapshot(of: player)
            let expectedEvents = model.takeEvents()
            defer { sent = [] }
            if expected != actual || expectedEvents != sent {
                return """
                after step \(step), \(operation):
                  model  \(expected)
                  player \(actual)
                  model events  \(expectedEvents)
                  player events \(sent)
                """
            }
        }
        return nil
    }

    static func apply(_ operation: Operation, to model: inout PlayerModel) {
        switch operation {
        case let .setItems(items, start, position): model.setItems(items, startIndex: start, startPosition: position)
        case let .insert(items, index): model.insert(items, at: index)
        case let .move(from, to): model.move(from: from, to: to)
        case let .remove(index): model.remove(at: index)
        case .removeAll: model.removeAll()
        case .play: model.play()
        case .pause: model.pause()
        case .stop: model.stop()
        case let .seek(position): model.seek(to: position)
        case let .seekItem(position, index): model.seek(to: position, itemAt: index)
        case .skipToNext: model.skipToNext()
        case .skipToPrevious: model.skipToPrevious()
        case let .repeatMode(mode): model.repeatMode = mode
        case let .pauseAtEndOfItem(value): model.pauseAtEndOfItem = value
        case let .advance(quarters): (0..<quarters).forEach { _ in model.tick() }
        }
    }

    /// Each call is followed by a pump, so the transport has answered before the comparison.
    static func apply(_ operation: Operation, to player: Player<String>, rig: PlayerRig) {
        switch operation {
        case let .setItems(items, start, position): player.setItems(items, startIndex: start, startPosition: position)
        case let .insert(items, index): player.insert(items, at: index)
        case let .move(from, to): player.move(from: from, to: to)
        case let .remove(index): player.remove(at: index)
        case .removeAll: player.removeAll()
        case .play: player.play()
        case .pause: player.pause()
        case .stop: player.stop()
        case let .seek(position): player.seek(to: position)
        case let .seekItem(position, index): player.seek(to: position, itemAt: index)
        case .skipToNext: player.skipToNext()
        case .skipToPrevious: player.skipToPrevious()
        case let .repeatMode(mode): player.repeatMode = mode
        case let .pauseAtEndOfItem(value): player.pauseAtEndOfItem = value
        case let .advance(quarters):
            for _ in 0..<quarters {
                rig.output.advance(by: 0.25)
                rig.pump()
            }
            return
        }
        rig.pump()
    }

    static func snapshot(of player: Player<String>) -> PlayerModel.Snapshot {
        PlayerModel.Snapshot(
            items: player.items,
            currentIndex: player.currentIndex,
            state: player.state,
            playWhenReady: player.playWhenReady,
            position: player.position,
            failed: player.error != nil,
            hasNext: player.hasNext,
            hasPrevious: player.hasPrevious
        )
    }

    // MARK: Shrinking

    /// Drops ever smaller runs of operations, then shortens clock steps, while the sequence still fails.
    static func shrink(_ operations: [Operation]) -> [Operation] {
        var current = operations
        var chunk = max(current.count / 2, 1)
        while chunk >= 1 {
            var start = 0
            var removedAny = false
            while start < current.count {
                var candidate = current
                candidate.removeSubrange(start..<min(start + chunk, current.count))
                if run(candidate) != nil {
                    current = candidate
                    removedAny = true
                } else {
                    start += chunk
                }
            }
            if !removedAny { chunk /= 2 }
        }
        for index in current.indices {
            guard case let .advance(quarters) = current[index] else { continue }
            for shorter in 1..<max(quarters, 1) {
                var candidate = current
                candidate[index] = .advance(quarters: shorter)
                if run(candidate) != nil {
                    current = candidate
                    break
                }
            }
        }
        return current
    }
}

/// Vigna's SplitMix64: seeded, so a seed replays its sequence on any machine.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(in range: Range<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}
