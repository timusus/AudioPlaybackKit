import Foundation
import Network

// A seeded fault plan for the body of every response, after media3's `FakeDataSource` fault plan:
// the same seed makes the same writes, pauses and drops, whichever test run it is.
extension LoopbackMediaServer {

    /// What the chaos plan does to the body of one response.
    enum ChaosFault: Equatable {
        /// Close with a FIN after this many body bytes: a body cut short, or a connection that drops.
        case disconnect(afterBytes: Int)
        /// As `disconnect`, but ending in a reset.
        case reset(afterBytes: Int)
        /// Stop writing after this many bytes and hold the connection open and silent, so only the
        /// client's own idle timeout (its clock) ends the attempt.
        case hang(afterBytes: Int)
    }

    /// Serve every body from `seed`: random short writes with random pauses between them, and, on
    /// the first few requests, one drop, reset or silent hang at a random byte. The requests after
    /// those are served whole (still in short, paced writes), so a client that retries always
    /// finishes. Nil is off. Replaces ``bytesPerSecond``, ``closesAfterBodyBytes`` and the other
    /// body shaping for the bodies it serves; the response header is unchanged.
    public var chaosSeed: UInt64? {
        get { lock.lock(); defer { lock.unlock() }; return _chaos?.seed }
        set { lock.lock(); _chaos = newValue.map { ChaosPlan(seed: $0) }; lock.unlock() }
    }

    /// How many of the first requests the plan may fault, from the seed: 0 to this minus one.
    /// Under the source's three answered failures in a row, so a chaos run is always recoverable.
    static let chaosMaxFaults = 3

    public enum ChaosFaultKind: Sendable { case disconnect, reset, hang }

    struct ChaosPlan {
        let seed: UInt64
        var requests = 0
        var faultsReached: [ChaosFaultKind] = []
        var openFault: ChaosFaultKind?
        init(seed: UInt64) { self.seed = seed }
    }

    /// The faults the plan has carried out so far, in order: a test that steps a manual clock waits
    /// on this (via ``ChangeSignal``) instead of guessing from silence that the origin has stopped.
    public var chaosFaultsReached: [ChaosFaultKind] {
        lock.lock(); defer { lock.unlock() }
        return _chaos?.faultsReached ?? []
    }

    /// The last fault reached, until the next request: the client is waiting out its backoff or
    /// idle timeout, so only its own clock moves it on.
    public var chaosOpenFault: ChaosFaultKind? {
        lock.lock(); defer { lock.unlock() }
        return _chaos?.openFault
    }

    private func reached(_ kind: ChaosFaultKind) {
        lock.lock()
        _chaos?.faultsReached.append(kind)
        _chaos?.openFault = kind
        lock.unlock()
        ChangeSignal.shared.notify()
    }

    /// SplitMix64: small, and stable across platforms and releases, unlike `SystemRandomNumberGenerator`.
    struct ChaosRandom {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(max(bound, 1))) }
    }

    /// The next request's random stream and fault, or nil when chaos is off.
    func nextChaos(bodyBytes: Int) -> (random: ChaosRandom, fault: ChaosFault?)? {
        lock.lock()
        guard var plan = _chaos else { lock.unlock(); return nil }
        let ordinal = plan.requests
        plan.requests += 1
        plan.openFault = nil
        _chaos = plan
        lock.unlock()

        // One stream per seed, so a request's fate depends on its place in the run only.
        var random = ChaosRandom(state: plan.seed &+ UInt64(ordinal) &* 0xD1B5_4A32_D192_ED03)
        var seedStream = ChaosRandom(state: plan.seed)
        let faultyRequests = seedStream.below(Self.chaosMaxFaults + 1)
        guard ordinal < faultyRequests, bodyBytes > 1 else { return (random, nil) }
        let at = 1 + random.below(bodyBytes - 1)
        switch random.below(3) {
        case 0: return (random, .disconnect(afterBytes: at))
        case 1: return (random, .reset(afterBytes: at))
        default: return (random, .hang(afterBytes: at))
        }
    }

    /// The header, then `slice` in random-sized writes with random short pauses, up to the fault.
    func sendChaotic(
        header: String, slice: Data, random: ChaosRandom, fault: ChaosFault?, on connection: NWConnection
    ) {
        let limit: Int = switch fault {
        case .disconnect(let n), .reset(let n), .hang(let n): min(n, slice.count)
        case nil: slice.count
        }
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { return }
            self.chaosWrite(slice, offset: 0, limit: limit, random: random, fault: fault, on: connection)
        })
    }

    private func chaosWrite(
        _ slice: Data, offset: Int, limit: Int, random: ChaosRandom, fault: ChaosFault?, on connection: NWConnection
    ) {
        guard offset < limit else {
            switch fault {
            case .hang: reached(.hang)
            case .reset:
                queue.asyncAfter(deadline: .now() + Self.shortBodyCloseDelay) {
                    connection.forceCancel()
                    self.reached(.reset)
                }
            case .disconnect:
                queue.asyncAfter(deadline: .now() + Self.shortBodyCloseDelay) {
                    connection.cancel()
                    self.reached(.disconnect)
                }
            case nil: connection.cancel()
            }
            return
        }
        var random = random
        let size = 1 + random.below(16 * 1024)
        let end = min(offset + size, limit)
        let pause = random.below(4) == 0 ? Double(random.below(4)) / 1000 : 0
        lock.lock(); _servedBytes += Int64(end - offset); lock.unlock()
        connection.send(content: slice.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { return }
            self.queue.asyncAfter(deadline: .now() + pause) {
                self.chaosWrite(slice, offset: end, limit: limit, random: random, fault: fault, on: connection)
            }
        })
    }
}
