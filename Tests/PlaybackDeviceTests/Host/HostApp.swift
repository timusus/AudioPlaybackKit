import SwiftUI

/// The process the device tests run in; the tests build their own player.
@main
struct HostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Playback device tests")
                // A backgrounded host cannot activate a non-mixable session (`!int`), so the phone must not auto-lock mid-run.
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}
