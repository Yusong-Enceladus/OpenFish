import Foundation

/// Prevents macOS idle sleep while an agent turn is running.
final class IdleGuard {
    private var activity: NSObjectProtocol?

    func start() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "An OpenFish task is running through DSH"
        )
    }

    func stop() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }
}
