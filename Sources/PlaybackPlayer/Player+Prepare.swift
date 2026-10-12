import Foundation

extension Player {
    /// media3 `Player.prepare()`: from `.idle`, stopped or failed, loads the current item at `position`
    /// with the list kept, and clears `error`. With `playWhenReady` it plays, as `play()` would;
    /// otherwise it buffers and is `.ready`, paused. In any other state it does nothing.
    public func prepare() {
        guard state == .idle, let current = currentIndex else { return }
        if playWhenReady { return play() }
        load(current, at: position)
    }
}
