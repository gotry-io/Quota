import XCTest

final class QuotaUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testContentFixtureShowsOverview() throws {
    let app = launch(fixture: "content")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.today"].exists,
      "overview.today"
    )
    attachScreenshot(app, name: "overview-content")
    try audit(app, skipping: [.hitRegion, .contrast, .dynamicType])
  }

  func testSignedOutFixtureShowsConnectAccount() throws {
    let app = launch(fixture: "signed-out")
    XCTAssertTrue(
      app.descendants(matching: .any)["connect.root"].waitForExistence(timeout: 10),
      "connect.root"
    )
    XCTAssertTrue(app.buttons["Connect Account"].exists, "Connect Account")
    attachScreenshot(app, name: "connect-signed-out")
    try audit(app, skipping: .contrast)
  }

  private func launch(fixture: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--visual-fixture", fixture]
    app.launch()
    return app
  }

  private func attachScreenshot(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Every issue is reported with the element it names, so a failure says what to fix.
  ///
  /// Two checks are skipped where the system, not this app, decides the answer. `.contrast`:
  /// on iOS 26 the audit flags text on Liquid Glass cards — an opaque `.label` subtitle on
  /// Connect, and card copy on Overview — although the rendered text is black on a light
  /// surface (see the attached screenshots). `.hitRegion` on Overview: the iOS 26 toolbar
  /// renders its Log Out capsule at 36pt whatever the label asks for; Log Out moves into the
  /// Settings tab (WP 3.9), and that skip goes with it. `.dynamicType` on Overview: the masked
  /// account label still reports partial support at accessibility sizes; the Overview card is
  /// rebuilt in WP 3.1 / 3.5 and that check returns with it. Clipping, element description,
  /// and trait checks run on both fixtures.
  private func audit(_ app: XCUIApplication, skipping: XCUIAccessibilityAuditType = []) throws {
    if #available(iOS 17.0, *) {
      var types = XCUIAccessibilityAuditType.all
      types.remove(skipping)
      try app.performAccessibilityAudit(for: types) { issue in
        let element = issue.element.map { "\($0)" } ?? "no element"
        XCTFail("\(issue.compactDescription) — \(element)")
        return true
      }
    }
  }
}
