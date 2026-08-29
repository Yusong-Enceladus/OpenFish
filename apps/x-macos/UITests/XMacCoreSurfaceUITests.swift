import XCTest

@MainActor
final class OpenCodexCoreSurfaceUITests: XCTestCase {
    private func launchDemo(
        newTask: Bool = false,
        harnessCatalog: Bool = false,
        state: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "--openfish-demo"]
        if newTask { app.launchArguments.append("--openfish-demo-new-task") }
        if harnessCatalog { app.launchArguments.append("--openfish-demo-harness-catalog") }
        if let state { app.launchArguments.append("--openfish-demo-\(state)") }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }

    func testNativeTaskSurface() throws {
        let app = launchDemo(newTask: true)

        XCTAssertTrue(app.buttons["OpenFish.NewTask"].waitForExistence(timeout: 10))

        let composer = app.descendants(matching: .any)["OpenFish.Composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("native DSH event-stream walkthrough")

        let send = app.buttons["OpenFish.Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)

        // The primary product surface must stay native. Feature panels may use
        // WebKit later, but navigation/conversation/composer cannot be a WebView.
        XCTAssertEqual(app.webViews.count, 0)

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "opencodex-macos-core-surface"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testModelBrowserAndReasoningControlsRemainInteractive() throws {
        let app = launchDemo()

        let modelPicker = app.buttons["OpenFish.ModelPicker"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 10))
        XCTAssertTrue(modelPicker.isEnabled)
        modelPicker.click()

        let browser = app.groups["OpenFish.ModelBrowser"]
        let search = app.textFields["OpenFish.ModelBrowser.Search"]
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Choose a model"].exists)
        // The identifier mirrors the provider group advertised by the live
        // Harness fixture; it must not invent a provider alias in the UI.
        let modelRow = app.descendants(matching: .any)["OpenFish.ModelBrowser.Model.openai.gpt-5.6-sol"]
        XCTAssertTrue(modelRow.exists)

        search.click()
        search.typeText("GPT-5.6")
        XCTAssertTrue(modelRow.waitForExistence(timeout: 2))

        let done = app.buttons["OpenFish.ModelBrowser.Done"]
        XCTAssertTrue(done.exists)
        done.click()
        XCTAssertFalse(browser.waitForExistence(timeout: 2))

        let reasoning = app.descendants(matching: .any)["OpenFish.ReasoningPicker"]
        XCTAssertTrue(reasoning.waitForExistence(timeout: 5))
        XCTAssertTrue(reasoning.isEnabled)

        let account = app.descendants(matching: .any)["OpenFish.HarnessAccount"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertTrue(account.isEnabled)

        reasoning.click()
        XCTAssertTrue(app.menuItems["Low"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Medium"].exists)
        XCTAssertTrue(app.menuItems["High"].exists)
    }

    func testNewTaskKeepsIdentityControlsAndNoProjectAvailable() throws {
        let app = launchDemo(newTask: true)

        for identifier in [
            "OpenFish.HarnessPicker",
            "OpenFish.ModelPicker",
            "OpenFish.ReasoningPicker",
            "OpenFish.WorkspacePicker",
            "OpenFish.AccessMode",
        ] {
            XCTAssertTrue(
                app.descendants(matching: .any)[identifier].waitForExistence(timeout: 10),
                "Missing new-task identity control: \(identifier)"
            )
        }

        let workspace = app.descendants(matching: .any)["OpenFish.WorkspacePicker"]
        workspace.click()
        let noProject = app.menuItems["No Project"]
        XCTAssertTrue(noProject.waitForExistence(timeout: 3))
        noProject.click()
        // NSMenuButton does not consistently bridge SwiftUI's accessibility
        // value on every macOS release. The selected label is the visible,
        // user-facing contract and remains queryable as a static text child.
        // SwiftUI bridges a macOS Menu's visible selection as AXTitle (the
        // XCUI MenuButton title), not AXLabel. Query the user-visible title.
        XCTAssertTrue(app.menuButtons["No Project"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Other"].exists)
    }

    func testHarnessCatalogStartsSimpleAndCanCreateAPack() throws {
        let app = launchDemo(newTask: true, harnessCatalog: true)

        XCTAssertTrue(app.staticTexts["Harnesses"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.radioButtons["Overview"].exists)
        XCTAssertTrue(app.staticTexts["Recommended for"].exists)

        let newPack = app.buttons["New Pack"]
        XCTAssertTrue(newPack.exists)
        newPack.click()

        XCTAssertTrue(app.staticTexts["Create Harness Pack"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.radioButtons["Setup"].exists)
        XCTAssertGreaterThanOrEqual(app.textFields.count, 6)
        XCTAssertTrue(app.buttons["Install & Live Preflight"].exists)
        XCTAssertFalse(app.buttons["Install & Live Preflight"].isEnabled)
        keepScreenshot(of: app, named: "openfish-macos-harness-builder")
    }

    func testHarnessArchitectureTraceAndStudioRemainInspectable() throws {
        let app = launchDemo(newTask: true, harnessCatalog: true)

        XCTAssertTrue(app.staticTexts["Harnesses"].waitForExistence(timeout: 5))

        let map = app.radioButtons["Map"]
        XCTAssertTrue(map.exists)
        map.click()
        XCTAssertTrue(app.staticTexts["Architecture view"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.radioButtons["Relationship map"].exists)
        XCTAssertTrue(app.staticTexts["Every declared relationship"].exists)
        XCTAssertTrue(app.staticTexts["Declared connections"].exists)
        keepScreenshot(of: app, named: "openfish-macos-harness-map")

        let trace = app.radioButtons["Trace"]
        XCTAssertTrue(trace.exists)
        trace.click()
        XCTAssertTrue(app.staticTexts["Live task path"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Observed components"].exists)
        XCTAssertTrue(app.staticTexts["Execution trace"].exists)
        keepScreenshot(of: app, named: "openfish-macos-harness-trace")

        let studio = app.radioButtons["Studio"]
        XCTAssertTrue(studio.exists)
        studio.click()
        XCTAssertTrue(app.staticTexts["Create or import a Harness"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import Pack"].exists)
        XCTAssertTrue(app.buttons["Create Pack"].exists)
        keepScreenshot(of: app, named: "openfish-macos-harness-studio")
    }

    func testHarnessLabExplainsExactRoutesWithoutPretendingDemoIsLive() throws {
        let app = launchDemo()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.click()

        let harnessLab = app.staticTexts["Harness Lab"]
        XCTAssertTrue(harnessLab.waitForExistence(timeout: 5))
        harnessLab.click()

        XCTAssertTrue(app.staticTexts["1 · Task contract"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2 · Harnesses"].exists)
        XCTAssertTrue(app.staticTexts["3 · Demo routes"].exists)
        XCTAssertTrue(app.buttons["Refresh demo routes"].exists)
        XCTAssertTrue(app.staticTexts["Demo preview · synthetic · offline"].exists)
        XCTAssertTrue(app.staticTexts["DeepSeek Harness"].exists)
        XCTAssertTrue(app.staticTexts["Codex"].exists)
        XCTAssertTrue(app.buttons["Demo preview only"].exists)
        XCTAssertFalse(app.buttons["Demo preview only"].isEnabled)
        keepScreenshot(of: app, named: "openfish-macos-harness-lab")
    }

    func testHostLoadingRecoverableAndFatalStatesNeverRenderABlankTask() throws {
        for (state, title) in [
            ("loading", "Starting OpenFish Host"),
            ("recoverable", "OpenFish could not finish connecting"),
            ("fatal", "This Host is not compatible"),
        ] {
            let app = launchDemo(state: state)
            let availability = app.descendants(matching: .any)["OpenFish.Host.Availability"]
            XCTAssertTrue(availability.waitForExistence(timeout: 10), "Missing \(state) Host surface")
            XCTAssertTrue(app.staticTexts[title].exists)
            XCTAssertFalse(app.descendants(matching: .any)["OpenFish.Composer"].exists)
            app.terminate()
        }
    }

    func testCachedOfflineStateKeepsTasksReadableAndBlocksSending() throws {
        let app = launchDemo(state: "offline")
        XCTAssertTrue(app.descendants(matching: .any)["OpenFish.Host.Cached"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Design the offline sync flow"].exists)
        let send = app.buttons["OpenFish.Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertFalse(send.isEnabled)
    }

    func testEmptyStateOffersARealNewTaskSurface() throws {
        let app = launchDemo(state: "empty")
        XCTAssertTrue(app.staticTexts["Start with a task"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["OpenFish.WorkspacePicker"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["OpenFish.HarnessPicker"].exists)
    }

    private func keepScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
