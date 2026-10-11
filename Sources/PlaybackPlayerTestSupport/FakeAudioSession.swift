import Foundation
@_spi(Testing) import PlaybackPlayer

/// The session seam with no `AVAudioSession`: records each call, answers activations at once (or
/// holds them for `completeActivation`), can make them throw, and posts the events iOS would.
@MainActor
public final class FakeAudioSession {
    public enum Call: Equatable, Sendable {
        case configure, activate, deactivate
    }

    public private(set) var calls: [Call] = []
    /// Every later activation fails with this until it is set back to nil.
    public var activationError: (any Error)?
    /// Activations wait for `completeActivation` instead of answering at once.
    public var holdsActivation = false
    private var held: [@MainActor ((any Error)?) -> Void] = []
    private var handler: (@MainActor (AudioSessionEvent) -> Void)?

    public var activations: Int { calls.filter { $0 == .activate }.count }
    public var deactivations: Int { calls.filter { $0 == .deactivate }.count }
    public var configurations: Int { calls.filter { $0 == .configure }.count }

    public init() {}

    public func configure() {
        calls.append(.configure)
    }

    public func activate(completion: @escaping @MainActor ((any Error)?) -> Void) {
        calls.append(.activate)
        guard holdsActivation else { return completion(activationError) }
        held.append(completion)
    }

    public func deactivate() {
        calls.append(.deactivate)
    }

    @_spi(Testing) public func setEventHandler(_ handler: @escaping @MainActor (AudioSessionEvent) -> Void) {
        self.handler = handler
    }

    /// Answers the held activations with `activationError`.
    public func completeActivation() {
        let completions = held
        held = []
        completions.forEach { $0(activationError) }
    }

    public func interruptionBegan() {
        handler?(.interruptionBegan)
    }

    public func interruptionEnded(shouldResume: Bool) {
        handler?(.interruptionEnded(shouldResume: shouldResume))
    }

    // The route types are SPI (ADR-0019), so a route test imports PlaybackPlayer with `@_spi(Testing)`.
    @_spi(Testing)
    public func routeChanged(reason: AudioRouteChangeReason, previous: [AudioPortKind], current: [AudioPortKind]) {
        handler?(.routeChanged(reason: reason, previous: previous, current: current))
    }

    public func mediaServicesReset() {
        handler?(.mediaServicesReset)
    }
}

@_spi(Testing) extension FakeAudioSession: AudioSessionControlling {}
