import XCTest

final class ReaderInteractionTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    @MainActor private func application() -> XCUIApplication {
        let app = XCUIApplication()
        let path = ProcessInfo.processInfo.environment["GAVIN_SIMULATOR_SWIFT"] ?? ""
        XCTAssertTrue(path.hasPrefix("/"), "Simulator Swift overlay path was not passed to the UI test runner")
        app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        return app
    }
    @MainActor func testEveryReadingRegionAdvancesAndLongPressOpensMenu() {
        for curl in [false, true] {
            let app = application()
            app.launchArguments = ["--ui-reading", "--ui-all-next"] + (curl ? ["--ui-curl"] : [])
            app.launch()
            let indicator = app.staticTexts["reader.pageIndicator"]
            XCTAssertTrue(indicator.waitForExistence(timeout: 15))
            let points: [(CGFloat, CGFloat)] = [(0.02, 0.2), (0.5, 0.4), (0.98, 0.6), (0.5, 0.94)]
            for (index, point) in points.enumerated() {
                app.coordinate(withNormalizedOffset: CGVector(dx: point.0, dy: point.1)).tap()
                let expected = NSPredicate(format: "label BEGINSWITH %@", "\(index + 2) / ")
                expectation(for: expected, evaluatedWith: indicator)
                waitForExpectations(timeout: 5)
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0.7)
            XCTAssertTrue(app.buttons["返回书架"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor func testImportPreviewCanConfirmAndPersistFromScreen() {
        let app = application()
        app.launchArguments = ["--ui-tab", "2", "--ui-import-preview"]
        app.launch()
        let confirm = app.buttons["确认导入 1 个书源"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Gavin 导入链路测试"].firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-tab", "2"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Gavin 导入链路测试"].firstMatch.waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor func testSearchAggregatesSourcesPagesAndRemembersHistory() {
        let app = application()
        app.launchArguments = ["--ui-tab", "1", "--ui-search-fixture"]
        app.launch()
        let submit = app.buttons["search.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 15))
        let query = app.textFields["search.query"]
        expectation(for: NSPredicate(format: "value == %@", "公版"), evaluatedWith: query)
        waitForExpectations(timeout: 15)
        submit.tap()
        let count = app.staticTexts["search.count"]
        expectation(for: NSPredicate(format: "label == %@", "2 本 · 4 条书源结果"), evaluatedWith: count)
        waitForExpectations(timeout: 15)
        let row = app.buttons["search.result.公版小说"]
        XCTAssertTrue(row.exists); row.tap()
        XCTAssertTrue(app.staticTexts["搜索测试甲"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["搜索测试乙"].exists)
        app.buttons["关闭"].tap()
        app.swipeUp()
        let more = app.buttons["search.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        expectation(for: NSPredicate(format: "label == %@", "3 本 · 6 条书源结果"), evaluatedWith: count)
        waitForExpectations(timeout: 10)
        app.terminate()
        app.launchArguments = ["--ui-tab", "1"]
        app.launch()
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "公版").firstMatch.waitForExistence(timeout: 10))
        app.terminate()
    }
}
