import AppKit
import SwiftUI

enum OpenFishDemoMode {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains { $0 == "--openfish-demo" || $0.hasPrefix("--openfish-demo-") }
    static let showsNewTask = ProcessInfo.processInfo.arguments.contains("--openfish-demo-new-task")
    static let showsHarnessCatalog = ProcessInfo.processInfo.arguments.contains("--openfish-demo-harness-catalog")
    static let showsHarnessRuntime = ProcessInfo.processInfo.arguments.contains("--openfish-demo-harness-runtime")
    static let showsLoading = ProcessInfo.processInfo.arguments.contains("--openfish-demo-loading")
    static let showsOffline = ProcessInfo.processInfo.arguments.contains("--openfish-demo-offline")
    static let showsRecoverable = ProcessInfo.processInfo.arguments.contains("--openfish-demo-recoverable")
    static let showsFatal = ProcessInfo.processInfo.arguments.contains("--openfish-demo-fatal")
    static let showsEmpty = ProcessInfo.processInfo.arguments.contains("--openfish-demo-empty")

    @MainActor
    static func store() -> OpenCodexStore {
        if showsHarnessRuntime { return .visualHarnessRuntimeFixture() }
        if showsHarnessCatalog { return .visualHarnessOnboardingFixture() }
        if showsLoading { return .visualLoadingFixture() }
        if showsOffline { return .visualOfflineFixture() }
        if showsRecoverable { return .visualRecoverableFixture() }
        if showsFatal { return .visualFatalFixture() }
        if showsEmpty { return .visualEmptyFixture() }
        return showsNewTask ? .visualNewTaskFixture() : .visualFixture()
    }
}

/// UI tests and deterministic demo captures must never inherit a stale window
/// origin from another display. Keeping this local to demo mode avoids
/// overriding a real user's preferred window placement.
struct OpenFishDemoWindowPositioner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        OpenFishDemoWindowPositioningView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class OpenFishDemoWindowPositioningView: NSView {
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.isRestorable = false
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        positionOnPrimaryDisplay(window)

        // SwiftUI can finish restoring a window after the representable joins
        // the hierarchy, so position it on the next main-loop turn.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            self.positionOnPrimaryDisplay(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        positionOnPrimaryDisplay(window)
    }

    private func positionOnPrimaryDisplay(_ window: NSWindow) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
            return
        }
        let visible = screen.visibleFrame
        let size = NSSize(
            width: min(max(window.frame.width, 980), visible.width),
            height: min(max(window.frame.height, 680), visible.height)
        )
        let frame = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        if !window.frame.equalTo(frame) {
            window.setFrame(frame, display: true)
        }
    }
}

private enum OpenFishLegacyPreferences {
    private static let legacyDomain = "ai.deepseek.opencodex"
    private static let migrationMarker = "OpenFish.didMigrateLegacyPreferences.v1"

    static func migrateIfNeeded() {
        let current = UserDefaults.standard
        guard !current.bool(forKey: migrationMarker) else { return }
        if let legacy = current.persistentDomain(forName: legacyDomain) {
            for (key, value) in legacy where key.hasPrefix("OpenCodex.") || key.hasPrefix("OpenFish.") {
                if current.object(forKey: key) == nil { current.set(value, forKey: key) }
            }
        }
        current.set(true, forKey: migrationMarker)
    }
}

@main
struct OpenCodexApp: App {
    init() {
        guard !OpenFishDemoMode.isEnabled else { return }
        OpenFishLegacyPreferences.migrateIfNeeded()
        OpenFishHostRuntime.bootstrapIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                store: OpenFishDemoMode.isEnabled ? OpenFishDemoMode.store() : nil,
                shouldBoot: !OpenFishDemoMode.isEnabled
            )
                .frame(minWidth: 980, minHeight: 680)
                .background {
                    if OpenFishDemoMode.isEnabled {
                        OpenFishDemoWindowPositioner()
                            .frame(width: 0, height: 0)
                    }
                }
        }
        .defaultSize(width: 1_260, height: 820)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
