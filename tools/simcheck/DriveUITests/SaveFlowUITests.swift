import XCTest

/// 保存の流れをシミュレータで通す(2026-11-10)。
///
/// 1. デモページの MP4 → 写真
/// 2. 音声(M4A)を MP3 → ファイル(保存先の選択画面が出るところまで)。
///    デモの動画には音声トラックが無い(「音声が入っていません」になる)ので音声で試す
/// 3. HLS(Apple の bipbop、30分)を最低画質で → 写真
///
/// 写真への追加は `xcrun simctl privacy <UDID> grant photos-add jp.kaba.imagebrowser` で
/// 先に許可しておく。結果の中身(長さ・トラック)は run_saveflow.sh が DCIM とアプリのログで確かめる。
final class SaveFlowUITests: XCTestCase {

    let demoURL = "https://kaba-0616.github.io/imagebrowser-demo/videobrowser/demo.html"
    // m3u8 を直接開くと iOS 標準の全画面プレーヤーになりツールバーが隠れるので、
    // <video> で埋め込んだページを Mac のローカルサーバー(run_saveflow.sh)から開く。
    let hlsURL = "http://localhost:8765/hls.html"

    override func setUp() { continueAfterFailure = false }

    func test1_MP4ToPhotos() throws {
        let app = launch()
        open(app, demoURL)
        openSaveSheet(app, rowContaining: "夕焼けの海")
        // 保存の前にその場で再生できる(2026-11-11)。
        app.buttons["プレビューを再生"].tap()
        sleep(4)
        shot("1-プレビュー再生")
        app.buttons["保存する"].tap()
        XCTAssertTrue(app.staticTexts["写真に保存しました"].waitForExistence(timeout: 60))
        shot("1-MP4完了")
        // 「戻る」で一覧へ(保存画面は一覧の上に積まれている)。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(2)
        shot("1-一覧へ戻る")
        XCTAssertTrue(app.navigationBars["動画・音声"].exists)
    }

    func test2_MP3ToFiles() throws {
        let app = launch()
        open(app, demoURL)
        openSaveSheet(app, rowContaining: "おやすみBGM")
        // 音声の形式は初めから MP3(AudioOutputFormat の既定)。
        let format = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '形式,'")).firstMatch
        XCTAssertTrue((format.label).contains("MP3"), format.label)
        shot("2-MP3設定")
        app.buttons["保存する"].tap()
        // 保存先の選択画面(UIDocumentPicker)が出れば変換は終わっている。
        let picker = app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS 'FullDocumentManager' OR identifier CONTAINS 'DOC'")).firstMatch
        let ok = app.staticTexts["保存先を選んでください"].waitForExistence(timeout: 60) || picker.waitForExistence(timeout: 5)
        shot("2-MP3保存先")
        tree(app, "2-中身")
        XCTAssertTrue(ok)
    }

    func test3_HLSToPhotos() throws {
        let app = launch()
        open(app, hlsURL)
        sleep(5)
        app.buttons["動画・音声を保存"].tap()
        sleep(3)
        shot("3-一覧")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'ストリーミング'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        sleep(5)
        // 画質は一番下(最低)を選ぶ。
        let quality = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '画質,'")).firstMatch
        if quality.waitForExistence(timeout: 15) {
            quality.tap(); sleep(2)
            shot("3-画質")
            tree(app, "3-画質中身")
            let options = app.collectionViews.buttons.allElementsBoundByIndex
            if let last = options.last { last.tap(); sleep(1) }
        }
        shot("3-設定")
        app.buttons["保存する"].tap()
        let done = app.staticTexts["写真に保存しました"].waitForExistence(timeout: 420)
        shot("3-HLS完了")
        tree(app, "3-中身")
        XCTAssertTrue(done)
    }

    /// 4. スクロールで <video> が足されるページ(scroll.html)で、一覧を開かなくても
    ///    バッジの件数が増えること。続けて全部を選んで写真へまとめて保存。
    func test4_ScrollAndBatch() throws {
        let app = launch()
        open(app, "http://localhost:8766/scroll.html")
        let button = app.buttons["動画・音声を保存"]
        let before = (button.value as? String) ?? ""
        shot("4-スクロール前")
        for _ in 0..<8 { app.webViews.firstMatch.swipeUp(); sleep(1) }
        sleep(3)
        let after = (button.value as? String) ?? ""
        print("SCROLLCHECK before=\(before) after=\(after)")
        shot("4-スクロール後")
        XCTAssertNotEqual(before, after)

        button.tap()
        sleep(3)
        app.navigationBars.buttons["選択"].tap()
        sleep(1)
        app.buttons["すべて選択"].tap()
        sleep(1)
        shot("4-選択")
        app.buttons.matching(NSPredicate(format: "label ENDSWITH '件を保存'")).firstMatch.tap()
        sleep(3)
        shot("4-まとめて保存")
        app.buttons.matching(NSPredicate(format: "label ENDSWITH '件を保存する'")).firstMatch.tap()
        let done = app.staticTexts["写真に保存しました"].waitForExistence(timeout: 180)
        shot("4-完了")
        tree(app, "4-中身")
        XCTAssertTrue(done)
    }

    // MARK: -

    private func launch() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "jp.kaba.imagebrowser")
        app.launch()
        sleep(4)
        return app
    }

    private func open(_ app: XCUIApplication, _ url: String) {
        let field = app.textFields["URLまたは検索ワード"].exists
            ? app.textFields["URLまたは検索ワード"] : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); sleep(1)
        for _ in 0..<3 {
            field.typeKey("a", modifierFlags: .command)
            sleep(1)
            field.typeText(url)
            sleep(1)
            if (field.value as? String) == url { break }
        }
        field.typeText("\n")
        sleep(10)
    }

    private func openSaveSheet(_ app: XCUIApplication, rowContaining text: String) {
        app.buttons["動画・音声を保存"].tap()
        sleep(4)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        sleep(3)
    }

    private func choose(_ app: XCUIApplication, _ title: String, _ option: String) {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch.tap()
        sleep(2)
        app.buttons[option].tap()
        sleep(1)
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }

    private func tree(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }
}
