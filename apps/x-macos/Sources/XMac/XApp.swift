import SwiftUI

enum OpenFishDemoMode {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--openfish-demo")
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
                store: OpenFishDemoMode.isEnabled ? .visualFixture() : nil,
                shouldBoot: !OpenFishDemoMode.isEnabled
            )
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1_260, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
