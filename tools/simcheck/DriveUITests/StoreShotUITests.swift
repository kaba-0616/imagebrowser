import XCTest

/// ストア用スクリーンショットの元画像を撮る。
///
/// 撮るのは既存の3枚と同じ構図: A 長押しの保存メニュー / B 一括抽出の一覧 /
/// C タブ一覧。**ページは自前のデモページだけを使う**(既定の Google には
/// トレンドの語句が出るので写さない)。
final class StoreShotUITests: XCTestCase {

    let pageURL = "https://kaba-0616.github.io/imagebrowser-demo/demo.html"

    override func setUp() { continueAfterFailure = true }

    func testStoreShots() throws {
        let app = XCUIApplication(bundleIdentifier: "jp.kaba.imagebrowser")
        app.launch()
        sleep(5)

        let field = app.textFields["URLまたは検索ワード"].exists
            ? app.textFields["URLまたは検索ワード"] : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); sleep(1)
        // タップしても既存のURLは残り、カーソルは押した位置に入る。削除キーの連打は
        // 消しきれず**後ろの文字が残って 404 を開く**ので、全選択して上書きする。
        var typed = false
        for _ in 0..<3 {
            field.typeKey("a", modifierFlags: .command)
            sleep(1)
            field.typeText(pageURL)
            sleep(1)
            if (field.value as? String) == pageURL { typed = true; break }
            note("入力違い: \(field.value ?? "nil")")
        }
        XCTAssertTrue(typed)
        field.typeText("\n")
        sleep(10)
        shot("0-ページ")

        // 本文の最初の写真を長押し。位置は画面の比率で指定する。
        app.windows.element(boundBy: 0)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.62))
            .press(forDuration: 1.2)
        sleep(2)
        shot("A-長押し")
        tree(app, "A-中身")
        app.windows.element(boundBy: 0)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.12)).tap()
        sleep(2)

        app.buttons["photo.stack"].tap()
        sleep(10)
        shot("B-一覧")
        tree(app, "B-中身")

        let all = app.buttons["全て選択"]
        if all.waitForExistence(timeout: 5) { all.tap(); sleep(2) }
        shot("B2-選択")

        let close = app.buttons["閉じる"]
        if close.waitForExistence(timeout: 5) { close.tap(); sleep(2) }

        let tabs = app.buttons.matching(NSPredicate(format: "label == '1'")).firstMatch
        if tabs.waitForExistence(timeout: 5) { tabs.tap(); sleep(3) }
        shot("C-タブ")
        tree(app, "C-中身")
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }

    private func note(_ text: String) {
        let a = XCTAttachment(string: text)
        a.name = "メモ"; a.lifetime = .keepAlways
        add(a)
    }

    private func tree(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }
}
