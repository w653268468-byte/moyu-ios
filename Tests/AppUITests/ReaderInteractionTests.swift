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
    override func tearDown() {
        if let testRun, testRun.failureCount > 0 {
            MainActor.assumeIsolated {
                let hierarchy = XCTAttachment(string: XCUIApplication().debugDescription)
                hierarchy.name = "failure-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            }
        }
        super.tearDown()
    }
    @MainActor private func tapMenu(_ element: XCUIElement) {
        // SwiftUI Menu sometimes rejects AXScrollToVisible even when its label is
        // already on screen. Tap the visible label, then still verify the menu items.
        let app = XCUIApplication()
        if element.label.hasPrefix("在线书籍管理：") {
            let scroll = app.scrollViews["shelf.scroll"]
            let bottom = app.tabBars.firstMatch.frame.minY - 4
            let top = app.buttons["书架显示与管理"].frame.maxY + 4
            for _ in 0..<6 {
                if element.isHittable, element.frame.minY >= top, element.frame.maxY <= bottom { break }
                scroll.swipeUp()
            }
            XCTAssertTrue(element.isHittable)
            XCTAssertGreaterThanOrEqual(element.frame.minY, top)
            XCTAssertLessThanOrEqual(element.frame.maxY, bottom)
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(app.frame.intersects(element.frame))
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    @MainActor private func enableSwitch(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        if element.value as? String != "1" {
            // SwiftUI exposes the whole labelled row as a switch. Its midpoint can
            // be inert text; the actual control is at the trailing edge.
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        }
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }
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
            let canvas = app.descendants(matching: .any)[curl ? "reader.curlCanvas" : "reader.pageCanvas"].firstMatch
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(canvas.frame.width, app.frame.width - 2, "The page animation must cover the screen width, including paper margins")
            XCTAssertGreaterThanOrEqual(canvas.frame.height, app.frame.height - 2, "Fullscreen must turn the whole page, including top and bottom paper")
            let text = app.descendants(matching: .any)["reader.pageText"].firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(text.frame.minY, 60, "The paper fills the screen, but text must avoid the island")
            XCTAssertLessThanOrEqual(text.frame.maxY, app.frame.maxY - 30)
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

    @MainActor func testNetworkVoiceImportAndSelectionPersist() {
        let app = application(); app.launchArguments = ["--ui-tab", "3"]; app.launch()
        XCTAssertTrue(app.buttons["在线音色与朗读"].waitForExistence(timeout: 10)); app.buttons["在线音色与朗读"].tap()
        app.buttons["voices.import"].tap()
        let input = app.textViews["voices.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("http://127.0.0.1:18765/tts-config.json")
        app.buttons["voices.parse"].tap()
        XCTAssertTrue(app.buttons["voices.confirm"].waitForExistence(timeout: 10)); app.buttons["voices.confirm"].tap()
        XCTAssertTrue(app.buttons["voice.use.991"].waitForExistence(timeout: 5)); app.buttons["voice.use.991"].tap()
        app.terminate(); app.launch()
        app.buttons["在线音色与朗读"].tap()
        XCTAssertTrue(app.buttons["voice.use.991"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["voice.use.991"].value as? String, "已选择")
        XCTAssertTrue(app.staticTexts["本地测试音色"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "network-voice-imported"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["系统离线朗读"].tap(); app.terminate()
    }

    @MainActor func testSourceHealthProbeCleanupAndRecoveryKeepRestrictedSource() {
        let app = application(); app.launchArguments = ["--ui-tab", "2", "--ui-source-health"]; app.launch()
        XCTAssertTrue(app.buttons["sources.probe"].waitForExistence(timeout: 10)); app.buttons["sources.probe"].tap()
        let cleanup = app.buttons["sources.cleanup"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: cleanup); waitForExpectations(timeout: 15)
        XCTAssertTrue(app.staticTexts["登录测试源"].exists)
        cleanup.tap(); app.buttons["备份并删除失效源"].tap()
        XCTAssertFalse(app.staticTexts["失效测试源"].exists)
        XCTAssertTrue(app.staticTexts["登录测试源"].exists)
        tapMenu(app.buttons["sources.actions"]); app.buttons["恢复上次清理"].tap()
        XCTAssertTrue(app.staticTexts["失效测试源"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["登录测试源"].exists)
        app.terminate()
    }

    @MainActor func testPreloadedChapterAvoidsAnotherLoadingPageAndDefaultsToLight() {
        let app = application(); app.launchArguments = ["--ui-tab", "0", "--ui-prefetch-reader", "-AppleInterfaceStyle", "Dark"]; app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "预加载测试书")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        let ready = app.staticTexts["prefetch.ready"]
        expectation(for: NSPredicate(format: "label == %@", "ready:2"), evaluatedWith: ready); waitForExpectations(timeout: 15)
        XCTAssertEqual(app.staticTexts["prefetch.cold"].label, "cold:1")
        app.buttons["下一章"].tap()
        let page = app.descendants(matching: .any)["reader.pageText"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "第2章已预取"), evaluatedWith: page); waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["prefetch.cold"].label, "cold:1", "Preloaded chapter reopened the loading page")
        app.buttons["返回书架"].tap(); app.tabBars.buttons["设置"].tap()
        let appearance = app.descendants(matching: .any)["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        XCTAssertTrue(appearance.label.contains("浅色纸白") || appearance.value as? String == "浅色纸白")
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "light-interface-on-dark-system"; capture.lifetime = .keepAlways; add(capture)
        app.terminate()
    }

    @MainActor func testPullToRefreshShelfShowsNewChapterAndRetainsItAfterRelaunch() {
        let app = application(); app.launchArguments = ["--ui-tab", "0", "--ui-shelf-refresh"]; app.launch()
        XCTAssertTrue(app.staticTexts["最新：第3章 测试"].waitForExistence(timeout: 15))
        let scroll = app.scrollViews["shelf.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(scroll.frame.height, app.frame.height * 0.5)
        let header = app.staticTexts["我的书架"]
        XCTAssertTrue(header.isHittable)
        // ScrollView's AX frame includes the navigation/search bars. Use actual
        // visible content as the drag origin so this gesture reaches its pan recognizer.
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(app.staticTexts["最新：第4章 测试"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["新增 1 章"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "shelf-refreshed"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate(); app.launchArguments = ["--ui-tab", "0"]; app.launch()
        XCTAssertTrue(app.staticTexts["最新：第4章 测试"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["新增 1 章"].exists)
        app.terminate()
    }

    @MainActor func testShelfGroupsPinAndBothLayoutsPersist() {
        let app = application(); app.launchArguments = ["--ui-tab", "0", "--ui-online-shelf"]; app.launch()
        XCTAssertTrue(app.buttons["书架显示与管理"].waitForExistence(timeout: 15)); tapMenu(app.buttons["书架显示与管理"])
        app.buttons["管理分组"].tap()
        let name = app.textFields["shelf.group.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("UI Reading")
        app.buttons["shelf.group.create"].tap(); app.buttons["完成"].tap()
        tapMenu(app.buttons["在线书籍管理：离线书架测试"]); app.buttons["分组与置顶"].tap()
        enableSwitch(app.switches["shelf.pin"])
        enableSwitch(app.switches["UI Reading"]); app.buttons["完成"].tap()
        app.buttons["UI Reading"].tap()
        XCTAssertTrue(app.staticTexts["离线书架测试"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["置顶"].firstMatch.exists)
        tapMenu(app.buttons["书架显示与管理"]); app.buttons["网格书架"].tap()
        XCTAssertTrue(app.staticTexts["离线书架测试"].firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "shelf-group-grid"; screenshot.lifetime = .keepAlways; add(screenshot)
        tapMenu(app.buttons["书架显示与管理"]); app.buttons["列表书架"].tap()
        app.terminate(); app.launchArguments = ["--ui-tab", "0"]; app.launch()
        XCTAssertTrue(app.staticTexts["离线书架测试"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["置顶"].firstMatch.exists)
        app.buttons["未分组"].tap()
        XCTAssertFalse(app.staticTexts["离线书架测试"].firstMatch.exists)
        app.buttons["全部分组"].tap()
        app.terminate()
    }

    @MainActor func testTextReplacementActuallyChangesReadingAndDisablingRestoresOriginal() {
        let app = application(); app.launchArguments = ["--ui-tab", "3"]; app.launch()
        XCTAssertTrue(app.buttons["替换净化"].waitForExistence(timeout: 15)); app.buttons["替换净化"].tap()
        app.buttons["添加净化规则"].tap()
        let name = app.textFields["replace.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "UI Replace")
        app.textViews["replace.pattern"].tap(); app.textViews["replace.pattern"].typeText("ORIGINAL")
        app.textViews["replace.replacement"].tap(); app.textViews["replace.replacement"].typeText("REPLACED")
        app.buttons["replace.save"].tap()
        XCTAssertTrue(app.staticTexts["UI Replace"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--ui-reading", "--ui-all-next", "--ui-transform-sample"]; app.launch()
        let replaced = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "REPLACED reader text.")).firstMatch
        XCTAssertTrue(replaced.waitForExistence(timeout: 15))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0.7)
        tapMenu(app.buttons["阅读菜单"]); app.buttons["替换净化"].tap()
        let enabled = app.switches["启用 UI Replace"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5)); enabled.tap(); app.buttons["完成"].tap()
        let original = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "ORIGINAL reader text.")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "replacement-disabled-original-restored"; screenshot.lifetime = .keepAlways; add(screenshot)
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
