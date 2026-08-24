import SwiftUI
import UIKit

@main
struct OpenCodexIOSApp: App {
    init() {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["OPENCODEX_DEBUG_KEEP_AWAKE"] == "1"
            || environment["DEVICECTL_CHILD_OPENCODEX_DEBUG_KEEP_AWAKE"] == "1" {
            UIApplication.shared.isIdleTimerDisabled = true
        }
#endif
    }

    var body: some Scene {
        WindowGroup { OpenCodexIOSView() }
    }
}
