import Foundation

enum RenderEventBounds {
    /// Wall-clock upper bounds hold only on an idle Mac, so they run only with `RENDER_EVENT_BOUNDS=1`.
    static let enabled = ProcessInfo.processInfo.environment["RENDER_EVENT_BOUNDS"] == "1"
}
