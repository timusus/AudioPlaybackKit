import Foundation
@testable import PlaybackPlayer

/// The session seam with no `AVAudioSession`: records each call, answers activations at once (or
/// holds them for `completeActivation`), can make them throw, and posts the events iOS would.
@MainActor
final class FakeAudioSession: AudioSessionControlling {
    enum Call: Equatable {
        case configure, activate, deactivate
    }

    private(set) var calls: [Call] = []
    /// Every later activation fails with this until it is set back to nil.
    var activationError: (any Error)?
    /// Activations wait for `completeActivation` instead of answering at once.
    var holdsActivation = false
    private var held: [@MainActor ((any Error)?) -> Void] = []
    private var handler: (@MainActor (AudioSessionEvent) -> Void)?

    var activations: Int { calls.filter { $0 == .activate }.count }
    var deactivations: Int { calls.filter { $0 == .deactivate }.count }
    var configurations: Int { calls.filter { $0 == .configure }.count }

    func configure() {
        calls.append(.configure)
    }

    func activate(completion: @escaping @MainActor ((any Error)?) -> Void) {
        calls.append(.activate)
        guard holdsActivation else { return completion(activationError) }
        held.append(completion)
    }

    func deactivate() {
        calls.append(.deactivate)
    }

    func setEventHandler(_ handler: @escaping @MainActor (AudioSessionEvent) -> Void) {
        self.handler = handler
    }

    /// Answers the held activations with `activationError`.
    func completeActivation() {
        let completions = held
        held = []
        completions.forEach { $0(activationError) }
    }

    func interruptionBegan() {
        handler?(.interruptionBegan)
    }

    func interruptionEnded(shouldResume: Bool) {
        handler?(.interruptionEnded(shouldResume: shouldResume))
    }

    func routeChanged(reason: AudioRouteChangeReason, previous: [AudioPortKind], current: [AudioPortKind]) {
        handler?(.routeChanged(reason: reason, previous: previous, current: current))
    }

    func mediaServicesReset() {
        handler?(.mediaServicesReset)
    }
}
