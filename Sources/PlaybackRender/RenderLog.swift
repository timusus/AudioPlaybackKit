import Foundation
import os

/// Flush and rate diagnostics, `.notice` so they reach a device log without a debug profile.
let renderLog = Logger(subsystem: "com.simplecityapps.audioplaybackkit", category: "render")

func milliseconds(since start: DispatchTime, to end: DispatchTime = .now()) -> Double {
    Double(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1e6
}

func fixed(_ seconds: TimeInterval) -> String {
    String(format: "%.3f", seconds)
}
