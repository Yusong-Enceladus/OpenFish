import AppKit
import SwiftUI

@main
struct VisualSmoke {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        guard OpenCodexStore.visualFixture().currentModelLabel == "GPT-5.6-Sol · Medium" else {
            throw VisualSmokeError.modelEffortIsNotVisible
        }

        let outputDirectory = URL(
            fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/visual-smoke",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try render(.visualFixture(), scheme: .light, to: outputDirectory.appending(path: "opencodex-light.png"))
        try render(.visualFixture(), scheme: .dark, to: outputDirectory.appending(path: "opencodex-dark.png"))

        let newTask = OpenCodexStore.visualNewTaskFixture()
        guard newTask.currentPermissions != nil else {
            throw VisualSmokeError.newTaskControlsAreUnavailable
        }
        try render(newTask, scheme: .light, to: outputDirectory.appending(path: "opencodex-new-task.png"))

        let inspector = OpenCodexStore.visualFixture()
        inspector.isInspectorPresented = true
        try render(inspector, scheme: .dark, to: outputDirectory.appending(path: "opencodex-inspector.png"))
        print("OpenFish visual smoke rendered task, new-task, model effort, and inspector fixtures at 1260×820")
    }

    @MainActor
    private static func render(_ store: OpenCodexStore, scheme: ColorScheme, to output: URL) throws {
        let root = ContentView(store: store, shouldBoot: false)
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "en_US"))
            .frame(width: 1_260, height: 820)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_260, height: 820)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw VisualSmokeError.couldNotCreateBitmap
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw VisualSmokeError.couldNotEncodePNG
        }
        try data.write(to: output, options: .atomic)
    }
}

private enum VisualSmokeError: Error {
    case couldNotCreateBitmap
    case couldNotEncodePNG
    case modelEffortIsNotVisible
    case newTaskControlsAreUnavailable
}
