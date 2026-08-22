import XCTest

final class OpenCodexCoreSurfaceUITests: XCTestCase {
    func testNativeTaskSurface() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.buttons["OpenFish.NewTask"].waitForExistence(timeout: 10))
        app.buttons["OpenFish.NewTask"].click()

        let composer = app.textViews["OpenFish.Composer"]
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
}
