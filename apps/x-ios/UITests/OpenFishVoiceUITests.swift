import XCTest

final class OpenFishVoiceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchIsolatedApp() -> XCUIApplication {
        addUIInterruptionMonitor(withDescription: "Speech and microphone permission") { alert in
            for label in ["Allow", "Continue", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        let app = XCUIApplication()
        app.launchArguments = ["--openfish-voice-smoke"]
        app.launch()
        return app
    }

    @MainActor
    private func launchDemo(state: String? = nil, accessibilityText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--openfish-demo"]
        if let state { app.launchArguments.append("--openfish-demo-\(state)") }
        if accessibilityText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"]
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }

    @MainActor
    private func startVoice(_ app: XCUIApplication, iteration: Int) -> XCUIElement {
        let start = app.buttons["Start voice conversation"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        // Speech and microphone are separate system prompts on a fresh install.
        app.tap()
        app.tap()
        let end = app.buttons["End voice conversation"]
        XCTAssertTrue(end.waitForExistence(timeout: 10), "Voice UI did not open on iteration \(iteration)")
        XCTAssertEqual(app.state, .runningForeground, "OpenFish stopped running after voice start \(iteration)")
        return end
    }

    @MainActor
    func testRepeatedVoiceStartAndStopKeepsAppAlive() throws {
        let app = launchIsolatedApp()

        let start = app.buttons["Start voice conversation"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))

        for iteration in 1...5 {
            let end = startVoice(app, iteration: iteration)
            end.tap()
            XCTAssertTrue(start.waitForExistence(timeout: 10), "Voice UI did not close on iteration \(iteration)")
            XCTAssertEqual(app.state, .runningForeground, "OpenFish stopped running after voice stop \(iteration)")
        }
    }

    @MainActor
    func testDeniedMicrophoneRemainsRecoverable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--openfish-voice-smoke"]
        app.launchEnvironment["OPENFISH_FORCE_MICROPHONE_DENIED"] = "1"
        app.launch()

        let start = app.buttons["Start voice conversation"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.staticTexts["Microphone permission is required."].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
        app.buttons["End voice conversation"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
    }

    @MainActor
    func testPhysicalMicrophoneBecomesActiveAndSurvivesRepeatedStartStop() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("A physical iPhone is required to exercise AVAudioEngine input.")
#else
        let app = launchIsolatedApp()
        let status = app.descendants(matching: .any)["voice-status"]
        for iteration in 1...5 {
            let end = startVoice(app, iteration: iteration)
            let active = NSPredicate(format: "value == %@", "microphone active")
            expectation(for: active, evaluatedWith: status)
            waitForExpectations(timeout: 10)
            end.tap()
            XCTAssertTrue(app.buttons["Start voice conversation"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.state, .runningForeground)
        }
#endif
    }

    @MainActor
    func testMobileHostStatesAreExplicitAndNeverBlank() throws {
        for (state, title) in [
            ("loading", "Connecting to your Mac"),
            ("recoverable", "Could not reach this Mac"),
            ("fatal", "This Mac Host is not compatible"),
        ] {
            let app = launchDemo(state: state)
            XCTAssertTrue(
                app.descendants(matching: .any)["OpenFish.Mobile.Host.Availability"].waitForExistence(timeout: 10),
                "Missing \(state) Host surface"
            )
            XCTAssertTrue(app.staticTexts[title].exists)
            app.terminate()
        }
    }

    @MainActor
    func testMobileOfflineStateKeepsCachedTasksAndBlocksNewWork() throws {
        let app = launchDemo(state: "offline")
        XCTAssertTrue(app.descendants(matching: .any)["OpenFish.Mobile.Host.Cached"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Design the offline sync flow"].exists)
        let newTask = app.buttons["New task"]
        XCTAssertTrue(newTask.exists)
        XCTAssertFalse(newTask.isEnabled)
    }

    @MainActor
    func testMobileEmptyAndSetupStatesRemainUsableAtAccessibilityTextSize() throws {
        let empty = launchDemo(state: "empty", accessibilityText: true)
        XCTAssertTrue(empty.staticTexts["No tasks yet"].waitForExistence(timeout: 10))
        empty.terminate()

        let setup = launchDemo(state: "harness-catalog", accessibilityText: true)
        XCTAssertTrue(setup.staticTexts["Choose how OpenFish works"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testCurrentHarnessOpensItsDeclaredArchitecture() throws {
        let app = launchDemo()
        let currentHarness = app.buttons["OpenFish.iOS.CurrentHarness"]
        XCTAssertTrue(currentHarness.waitForExistence(timeout: 10))
        currentHarness.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["OpenFish.iOS.HarnessDetail"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["Map"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Relationship map"].exists)
        XCTAssertTrue(app.staticTexts["App-server"].exists)
        XCTAssertTrue(app.staticTexts["Thread & turn"].exists)
        XCTAssertTrue(app.staticTexts["Declared connections"].exists)
        keepScreenshot(of: app, named: "openfish-ios-harness-map")
    }

    @MainActor
    func testCurrentHarnessShowsAContentFreeOrderedRuntimeTrace() throws {
        let app = launchDemo()
        let currentHarness = app.buttons["OpenFish.iOS.CurrentHarness"]
        XCTAssertTrue(currentHarness.waitForExistence(timeout: 10))
        currentHarness.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["OpenFish.iOS.HarnessDetail"].waitForExistence(timeout: 5)
        )

        let runtime = app.buttons["Trace"]
        XCTAssertTrue(runtime.waitForExistence(timeout: 5))
        runtime.tap()

        let retained = app.staticTexts["Content-free · newest last · 17 retained"]
        XCTAssertTrue(retained.waitForExistence(timeout: 5))
        for _ in 0..<5 where !retained.isHittable { app.swipeUp() }
        if app.buttons["Show all"].exists {
            app.buttons["Show all"].tap()
        }

        let first = app.descendants(matching: .any)["OpenFish.iOS.HarnessTrace.20"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let last = app.descendants(matching: .any)["OpenFish.iOS.HarnessTrace.36"]
        for _ in 0..<10 where !last.exists { app.swipeUp() }
        XCTAssertTrue(last.exists)
        keepScreenshot(of: app, named: "openfish-ios-harness-trace")
    }

    @MainActor
    func testApprovalAndStructuredQuestionCompleteOnDevice() throws {
        let app = launchDemo(state: "interactions")
        let task = app.staticTexts["Design the offline sync flow"]
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()

        XCTAssertTrue(app.staticTexts["Permission requested"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OpenFish asks"].exists)

        let deny = app.buttons["Deny"]
        XCTAssertTrue(deny.exists)
        deny.tap()
        XCTAssertFalse(app.staticTexts["Permission requested"].waitForExistence(timeout: 2))

        let choice = app.buttons["Keep changes"]
        for _ in 0..<3 where !choice.exists {
            app.swipeUp()
        }
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        let submit = app.buttons["Submit answers"]
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertFalse(app.staticTexts["OpenFish asks"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testPhysicalPairedHostRecoversAfterBackground() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("A paired physical iPhone is required for the live Host lifecycle check.")
#else
        let app = XCUIApplication()
        app.launch()
        let newTask = app.buttons["New task"]
        guard newTask.waitForExistence(timeout: 15), newTask.isEnabled else {
            throw XCTSkip("This physical iPhone is not currently paired with a ready OpenFish Host.")
        }

        newTask.tap()
        XCTAssertTrue(app.staticTexts["Start a task"].waitForExistence(timeout: 10))
        let workspace = app.buttons["OpenFish.iOS.WorkspacePicker"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        let noProject = app.buttons["No Project"]
        XCTAssertTrue(noProject.waitForExistence(timeout: 5))
        noProject.tap()
        XCTAssertTrue(app.buttons["OpenFish.iOS.HarnessModelPicker"].waitForExistence(timeout: 15))

        XCUIDevice.shared.press(.home)
        XCTAssertEqual(app.state, .runningBackground)
        app.activate()

        XCTAssertTrue(app.staticTexts["Start a task"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["OpenFish.iOS.HarnessModelPicker"].exists)
        XCTAssertEqual(app.state, .runningForeground)
#endif
    }

    @MainActor
    private func keepScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
