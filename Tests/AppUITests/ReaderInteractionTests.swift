import XCTest

final class ReaderInteractionTests: XCTestCase {
    @MainActor func testBundledSourceSamplesPreviewAndImportWithoutDownloadingCollection() {
        let app = application(); app.launchArguments = ["--ui-tab", "2", "--ui-import-samples"]; app.launch()
        let sample = app.buttons["source.import.samples"]
        XCTAssertTrue(sample.waitForExistence(timeout: 15)); sample.tap()
        let confirm = app.buttons["确认导入 3 个书源"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.tap()
        XCTAssertTrue(app.staticTexts["奇异网"].firstMatch.waitForExistence(timeout: 10))
        app.terminate()
    }
    @MainActor func testSourceRequestedLoginAndImageCodeResumeScript() {
        let app = application(); app.launchArguments = ["--ui-verification-check"]; app.launch()
        let done = app.buttons["source.verification.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: done); waitForExpectations(timeout: 15)
        done.tap()
        let code = app.textFields["source.verification.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 15)); code.tap(); code.typeText("7319")
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: done); waitForExpectations(timeout: 15)
        done.tap()
        let result = app.staticTexts["source.verification.result"]
        expectation(for: NSPredicate(format: "label == %@", "passed"), evaluatedWith: result); waitForExpectations(timeout: 15)
        app.terminate()
    }
    @MainActor func testCancellingSourceVerificationReturnsToApp() {
        let app = application(); app.launchArguments = ["--ui-verification-check"]; app.launch()
        let cancel = app.buttons["source.verification.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15)); cancel.tap()
        let result = app.staticTexts["source.verification.result"]
        expectation(for: NSPredicate(format: "label == %@", "cancelled"), evaluatedWith: result); waitForExpectations(timeout: 10)
        app.terminate()
    }
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
            for _ in 0..<2 {
                let settings = app.buttons["阅读设置"]
                XCTAssertTrue(settings.waitForExistence(timeout: 5))
                expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: settings); waitForExpectations(timeout: 5)
                settings.tap()
                XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
                app.buttons["完成"].tap()
                let contents = app.buttons["目录与书签"]
                XCTAssertTrue(contents.waitForExistence(timeout: 5))
                expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: contents); waitForExpectations(timeout: 5)
                contents.tap()
                XCTAssertTrue(app.staticTexts["第一章 春日"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.segmentedControls["catalog.order"].buttons["倒序"].isHittable)
                app.segmentedControls["catalog.order"].buttons["倒序"].tap()
                app.segmentedControls["catalog.order"].buttons["正序"].tap()
                app.buttons["完成"].tap()
            }
            app.buttons["reader.progress"].tap()
            XCTAssertTrue(app.sliders["progress.slider"].waitForExistence(timeout: 5))
            app.sliders["progress.slider"].adjust(toNormalizedSliderPosition: 0)
            app.buttons["progress.confirm"].tap()
            XCTAssertTrue(app.buttons["目录与书签"].waitForExistence(timeout: 5))
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
        findImportedSource(in: app)
        app.terminate()
        app.launchArguments = ["--ui-tab", "2"]
        app.launch()
        findImportedSource(in: app)
        app.terminate()
    }

    @MainActor func testOnlineShelfOfflineReaderAndCatalogOrder() {
        let app = application(); app.launchArguments = ["--ui-tab", "0", "--ui-online-shelf"]; app.launch()
        let book = app.buttons.containing(.staticText, identifier: "离线书架测试").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        app.buttons["离线下载"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["离线下载"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已下载 3/3 章"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap(); book.tap()
        let indicator = app.staticTexts["reader.pageIndicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        if !app.buttons["章节目录"].isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0.7) }
        app.buttons["章节目录"].tap()
        let order = app.segmentedControls["catalog.order"]
        XCTAssertTrue(order.waitForExistence(timeout: 5))
        order.buttons["正序"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalog.chapter."))
        XCTAssertEqual(rows.element(boundBy: 0).identifier, "catalog.chapter.0")
        order.buttons["倒序"].tap()
        XCTAssertEqual(rows.element(boundBy: 0).identifier, "catalog.chapter.2")
        rows.element(boundBy: 0).tap()
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        app.buttons["章节目录"].tap()
        XCTAssertTrue(order.buttons["倒序"].isSelected)
        order.buttons["正序"].tap()
        XCTAssertEqual(rows.element(boundBy: 0).identifier, "catalog.chapter.0")
        XCTAssertTrue(app.buttons["catalog.current"].isHittable)
        app.buttons["catalog.refresh"].tap()
        XCTAssertTrue(app.staticTexts["原书源已移除，无法更新；已下载章节仍可阅读。"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["reader.progress"].tap()
        XCTAssertTrue(app.sliders["progress.slider"].waitForExistence(timeout: 5))
        app.sliders["progress.slider"].adjust(toNormalizedSliderPosition: 0)
        app.buttons["progress.confirm"].tap()
        app.buttons["章节目录"].tap()
        XCTAssertEqual(app.buttons["catalog.chapter.0"].value as? String, "当前章节")
        app.buttons["完成"].tap()
        app.buttons["reader.progress"].tap()
        let chapter = app.textFields["progress.chapter"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5)); chapter.tap(); chapter.typeText(XCUIKeyboardKey.delete.rawValue + "2")
        app.buttons["收起键盘"].tap()
        app.buttons["progress.chapter.confirm"].tap()
        app.buttons["章节目录"].tap()
        XCTAssertEqual(app.buttons["catalog.chapter.1"].value as? String, "当前章节")
        app.buttons["完成"].tap(); app.buttons["返回书架"].tap()
        app.terminate(); app.launchArguments = ["--ui-tab", "0"]; app.launch()
        XCTAssertTrue(app.staticTexts["离线书架测试"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["全书已下载 · 可离线阅读"].firstMatch.exists)
        app.terminate()
    }

    @MainActor func testRefreshCatalogAddsChapterAndPreservesCurrentDestination() {
        let app = application(); app.launchArguments = ["--ui-tab", "0", "--ui-catalog-refresh"]; app.launch()
        let book = app.buttons.containing(.staticText, identifier: "目录更新测试书").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        XCTAssertTrue(app.buttons["章节目录"].waitForExistence(timeout: 10)); app.buttons["章节目录"].tap()
        let order = app.segmentedControls["catalog.order"]
        XCTAssertTrue(order.waitForExistence(timeout: 5)); order.buttons["正序"].tap()
        XCTAssertEqual(app.buttons["catalog.chapter.0"].value as? String, "当前章节")
        app.buttons["catalog.refresh"].tap()
        XCTAssertTrue(app.staticTexts["已更新，新增 1 章，共 4 章。"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["catalog.chapter.0"].value as? String, "当前章节")
        app.buttons["完成"].tap(); app.buttons["返回书架"].tap()
        app.buttons["离线下载"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已下载 3/4 章"].waitForExistence(timeout: 10))
        app.buttons["完成"].tap(); book.tap(); app.buttons["章节目录"].tap()
        app.swipeUp()
        XCTAssertTrue(order.buttons["倒序"].isHittable); order.buttons["倒序"].tap()
        app.buttons["catalog.chapter.3"].tap()
        XCTAssertTrue(app.buttons["reader.progress"].waitForExistence(timeout: 10))
        app.buttons["章节目录"].tap()
        XCTAssertEqual(app.buttons["catalog.chapter.3"].value as? String, "当前章节")
        app.buttons["完成"].tap(); app.buttons["返回书架"].tap()
        app.terminate(); app.launchArguments = ["--ui-tab", "0"]; app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        app.buttons["章节目录"].tap()
        XCTAssertEqual(app.buttons["catalog.chapter.3"].value as? String, "当前章节")
        app.terminate()
    }

    @MainActor func testPullToRefreshShelfShowsNewChapterAndRetainsItAfterRelaunch() {
        let app = application(); app.launchArguments = ["--ui-tab", "0", "--ui-shelf-refresh"]; app.launch()
        XCTAssertTrue(app.staticTexts["最新：第3章 测试"].waitForExistence(timeout: 15))
        let scroll = app.scrollViews.firstMatch
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(app.staticTexts["最新：第4章 测试"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["新增 1 章"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "shelf-refreshed"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate(); app.launchArguments = ["--ui-tab", "0"]; app.launch()
        XCTAssertTrue(app.staticTexts["最新：第4章 测试"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["新增 1 章"].exists)
        app.terminate()
    }

    @MainActor private func findImportedSource(in app: XCUIApplication) {
        // Earlier tests import bundled samples into this same installed app.
        // A virtualized List need not expose a newly appended row until scrolled.
        let row = app.staticTexts["Gavin 导入链路测试"].firstMatch
        for _ in 0..<8 {
            if row.waitForExistence(timeout: 1) { break }
            app.swipeUp()
        }
        XCTAssertTrue(row.exists, "The imported source must be present before and after relaunch")
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
        app.swipeDown()
        expectation(for: NSPredicate(format: "label == %@", "3 本 · 6 条书源结果"), evaluatedWith: count)
        waitForExpectations(timeout: 10)
        app.terminate()
        app.launchArguments = ["--ui-tab", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["search.history.公版"].waitForExistence(timeout: 10))
        app.terminate()
    }
}
