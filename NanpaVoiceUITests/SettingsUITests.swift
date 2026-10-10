import XCTest

final class SettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// APIキーを保存すると伏せ字になり、削除すると入力欄に戻る
    @MainActor
    func testSaveAndDeleteApiKey() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["設定"].tap()

        // 前回の実行でキーが残っていたら消しておく
        if app.buttons["APIキーを削除"].waitForExistence(timeout: 2) {
            deleteKey(app)
        }

        let field = app.secureTextFields["sk-..."]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("sk-test-1234567890abcd")
        app.buttons["保存"].tap()

        // LabeledContentはラベルと値を1つの要素にまとめる
        XCTAssertTrue(app.staticTexts["保存済み, sk-••••••••abcd"].waitForExistence(timeout: 5))
        let leaked = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'sk-test-1234567890abcd'"))
        XCTAssertEqual(leaked.count, 0)

        deleteKey(app)
        XCTAssertTrue(app.secureTextFields["sk-..."].waitForExistence(timeout: 5))
    }

    @MainActor
    private func deleteKey(_ app: XCUIApplication) {
        app.buttons["APIキーを削除"].tap()
        let confirm = app.buttons.matching(identifier: "削除").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
    }
}
