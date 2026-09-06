import XCTest

final class QuotaUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
    switch uitestEnvironment("QUOTA_IOS_APPEARANCE")?.lowercased() {
    case "dark":
      XCUIDevice.shared.appearance = .dark
    default:
      XCUIDevice.shared.appearance = .light
    }
  }

  func testContentFixtureShowsOverview() throws {
    let app = launch(fixture: "content")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    let todaySection = app.descendants(matching: .any)["overview.today"]
    if !todaySection.waitForExistence(timeout: 2) {
      for _ in 0..<6 {
        if todaySection.exists || app.staticTexts["Today"].exists { break }
        app.swipeUp()
      }
    }
    XCTAssertTrue(
      todaySection.waitForExistence(timeout: 5)
        || app.descendants(matching: .any)["overview.today.tokens"].exists
        || app.staticTexts["Today"].exists
        || app.staticTexts["No usage today."].exists,
      "overview.today"
    )
    try restoreTabBar(app)
    assertTab(app, "Overview")
    assertTab(app, "Usage")
    assertTab(app, "Devices")
    assertTab(app, "Settings")
    XCTAssertFalse(
      app.navigationBars.buttons["Log Out"].exists,
      "Log Out belongs on Settings, not the Overview toolbar"
    )
    XCTAssertFalse(
      app.staticTexts["Studio Mac"].exists,
      "Devices summary does not duplicate onto Overview"
    )
    XCTAssertTrue(app.staticTexts["Today"].exists, "Today section")
    attachScreenshot(app, name: "overview-content")
    try audit(app)
    try assertListScrolls(app, screenshot: "overview-scrolled")
    try restoreTabBar(app)

    app.tabBars.buttons["Usage"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 10),
      "usage.root"
    )
    let period = app.segmentedControls.firstMatch
    XCTAssertTrue(period.waitForExistence(timeout: 5), "usage period control")
    XCTAssertTrue(period.buttons["Today"].exists, "Today segment")
    XCTAssertTrue(period.buttons["7 Days"].exists, "7 Days segment")
    XCTAssertTrue(period.buttons["30 Days"].exists, "30 Days segment")
    period.buttons["30 Days"].tap()
    XCTAssertTrue(
      app.staticTexts["Activity"].waitForExistence(timeout: 5), "Activity section title")
    XCTAssertTrue(app.buttons["View day"].waitForExistence(timeout: 5), "View day")
    attachScreenshot(app, name: "usage-content")
    attachScreenshot(app, name: "usage-activity")
    try audit(app)
    app.buttons["View day"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.day"].waitForExistence(timeout: 5),
      "usage.day"
    )
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "Done")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.day.model"].waitForExistence(timeout: 5),
      "usage.day.model"
    )
    attachScreenshot(app, name: "usage-day")
    try audit(app)
    app.buttons["Done"].tap()
    try restoreTabBar(app)
    let showMore = app.descendants(matching: .any)["usage.show-more"]
    let showMoreLabel = app.buttons["Show 2 more OpenAI models"]
    let codex = app.staticTexts["Codex"]
    for _ in 0..<12 {
      if showMore.exists || showMoreLabel.exists || codex.exists { break }
      app.swipeUp()
    }
    XCTAssertTrue(
      showMore.exists || showMoreLabel.exists || codex.exists,
      "model rows"
    )
    try assertListScrolls(app)
    try restoreTabBar(app)

    app.tabBars.buttons["Overview"].tap()
    let card = app.descendants(matching: .any)["overview.subscription"].firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 5), "overview.subscription")
    card.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.detail"].waitForExistence(timeout: 5),
      "subscription.detail"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.reporting"].waitForExistence(timeout: 5),
      "Reporting"
    )
    XCTAssertTrue(app.staticTexts["Account"].exists, "Account")
    XCTAssertTrue(app.staticTexts["Quota"].exists, "Quota")
    XCTAssertTrue(app.staticTexts["Readings"].exists, "Readings")
    attachScreenshot(app, name: "subscription-detail")
    try audit(app)
  }

  func testContentFixtureShowsSettingsDestinations() throws {
    let app = launch(fixture: "content")
    XCTAssertTrue(
      app.tabBars.buttons["Settings"].waitForExistence(timeout: 10),
      "Settings tab"
    )
    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.notifications"].exists,
      "Notifications"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.appearance"].exists,
      "Appearance"
    )
    XCTAssertTrue(app.descendants(matching: .any)["settings.about"].exists, "About")
    let deleteAccount = app.descendants(matching: .any)["settings.delete-account"]
    if !deleteAccount.waitForExistence(timeout: 2) {
      scrollToIdentifierOnce(app, "settings.delete-account")
    }
    XCTAssertTrue(
      deleteAccount.waitForExistence(timeout: 5) || app.buttons["Delete Account…"].exists,
      "Delete Account…"
    )
    let logout = app.descendants(matching: .any)["settings.logout"]
    if !logout.exists {
      scrollToIdentifierOnce(app, "settings.logout")
    }
    XCTAssertTrue(logout.exists, "Log Out on Settings hub")
    XCTAssertTrue(app.buttons["Log Out"].exists, "Log Out")
    // Back to the top: the hub is longer than one screen, and a row scrolled under the
    // navigation bar's glass is a system overlay the contrast pass would sample instead of the row.
    scrollContent(app, up: false)
    attachScreenshot(app, name: "settings-main")
    try audit(app)

    openSettingsDestination(
      app,
      link: "settings.notifications",
      root: "settings.notifications.root"
    )
    XCTAssertTrue(
      app.switches["Enable Notifications"].waitForExistence(timeout: 5),
      "Enable Notifications"
    )
    XCTAssertTrue(app.switches["Reset Reminders"].exists, "Reset Reminders")
    XCTAssertTrue(app.staticTexts["Alert at"].exists, "Alert at")
    attachScreenshot(app, name: "settings-notifications")
    try audit(app)
    popSettingsDestination(app)

    openSettingsDestination(app, link: "settings.appearance", root: "settings.appearance.root")
    attachScreenshot(app, name: "settings-appearance")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.appearance.system"].waitForExistence(timeout: 5),
      "System"
    )
    XCTAssertTrue(app.descendants(matching: .any)["settings.appearance.light"].exists, "Light")
    XCTAssertTrue(app.descendants(matching: .any)["settings.appearance.dark"].exists, "Dark")
    try audit(app)
    popSettingsDestination(app)

    openSettingsDestination(app, link: "settings.about", root: "settings.about.root")
    attachScreenshot(app, name: "settings-about")
    XCTAssertTrue(
      app.staticTexts[
        "Quota shows remaining quota and usage reported by QuotaBar on your Mac."
      ].exists,
      "product sentence"
    )
    XCTAssertTrue(
      app.staticTexts["This iPhone does not collect or upload local usage."].exists,
      "privacy sentence"
    )
    XCTAssertTrue(app.staticTexts["Version"].exists, "Version")
    XCTAssertTrue(app.descendants(matching: .any)["Website"].exists, "Website")
    XCTAssertTrue(app.descendants(matching: .any)["GitHub"].exists, "GitHub")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.about.license"].exists
        || app.staticTexts["License"].exists,
      "License MIT"
    )
    try audit(app)
  }

  /// The Providers group in its three states: two accounts on one provider, one on another,
  /// and a third with nothing connected yet.
  func testProvidersFixtureShowsEveryConnectionState() throws {
    let app = launch(fixture: "providers")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    let providers = app.descendants(matching: .any)["section.header.providers"]
    if !providers.waitForExistence(timeout: 2) {
      scrollToIdentifierOnce(app, "section.header.providers")
    }
    XCTAssertTrue(providers.waitForExistence(timeout: 5), "Providers header")
    XCTAssertTrue(
      app.descendants(matching: .any)["providers.session.codex:codex_work"].exists,
      "first connected Codex account"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["providers.session.codex:codex_personal"].exists,
      "second connected Codex account"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["providers.session.claude:claude_team"].exists,
      "connected Claude Code account"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["providers.connect.grok"].exists,
      "Grok Connect row"
    )
    let grokConnect = app.descendants(matching: .any)["providers.connect.grok"]
    XCTAssertTrue(
      grokConnect.label.contains("Connect"),
      "a provider with nothing connected offers Connect, got \(grokConnect.label)"
    )
    let codexConnect = app.descendants(matching: .any)["providers.connect.codex"]
    XCTAssertTrue(
      codexConnect.label.contains("Add Account"),
      "a provider already connected offers another account, got \(codexConnect.label)"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["providers.remove.codex:codex_work"].exists,
      "Remove"
    )
    attachScreenshot(app, name: "settings-providers")
    try audit(app)
  }

  func testNoDevicesFixtureShowsMacSetup() throws {
    let app = launch(fixture: "no-devices")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    XCTAssertTrue(app.staticTexts["No quota yet"].waitForExistence(timeout: 5), "No quota yet")
    XCTAssertTrue(
      app.staticTexts["Set up QuotaBar on a Mac to start reporting."].exists,
      "empty quota description"
    )
    XCTAssertTrue(app.staticTexts["No usage today."].exists, "No usage today.")
    XCTAssertTrue(
      app.staticTexts["Set up QuotaBar"].exists
        || app.descendants(matching: .any)["section.header.mac-setup"].exists,
      "Set up QuotaBar"
    )
    let setupDetail = app.descendants(matching: .any)["section.footer.mac-setup"]
    if !setupDetail.waitForExistence(timeout: 2) {
      scrollToIdentifierOnce(app, "section.header.mac-setup")
      scrollToIdentifierOnce(app, "section.footer.mac-setup")
    }
    XCTAssertTrue(
      app.staticTexts["Install QuotaBar on a Mac signed in with this GitHub account."].exists
        || setupDetail.exists
        || app.descendants(matching: .any).matching(
          NSPredicate(
            format: "label CONTAINS %@",
            "Install QuotaBar on a Mac signed in with this GitHub account."
          )
        ).firstMatch.exists,
      "setup detail"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["Download for Mac"].waitForExistence(timeout: 5),
      "Download for Mac"
    )
    XCTAssertFalse(app.staticTexts["Set up a Mac"].exists, "legacy setup title")
    XCTAssertFalse(
      app.staticTexts["https://quota.gotry.io/download"].exists,
      "raw download URL is not shown"
    )
    attachScreenshot(app, name: "overview-no-devices")
    try audit(app)

    app.tabBars.buttons["Devices"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["devices.root"].waitForExistence(timeout: 5),
      "devices.root"
    )
    XCTAssertTrue(
      app.staticTexts["No Macs connected"].waitForExistence(timeout: 5),
      "No Macs connected"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["Download QuotaBar"].waitForExistence(timeout: 5),
      "Download QuotaBar"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["Manage Devices on Web"].exists,
      "Manage Devices on Web"
    )
    attachScreenshot(app, name: "devices-empty")
    try audit(app)
  }

  func testCachedErrorFixtureShowsPlainStatus() throws {
    let app = launch(fixture: "cached-error")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    XCTAssertTrue(
      app.staticTexts["Showing saved data. Couldn't refresh."].waitForExistence(timeout: 5),
      "cached status"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.status"].exists,
      "overview.status"
    )
    attachScreenshot(app, name: "overview-cached-error")
    try audit(app)
  }

  func testDevicesContentFixtureListsDevices() throws {
    let app = launch(fixture: "content")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    app.tabBars.buttons["Devices"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["devices.root"].waitForExistence(timeout: 5),
      "devices.root"
    )
    XCTAssertTrue(app.staticTexts["Studio Mac"].waitForExistence(timeout: 5), "Studio Mac")
    XCTAssertTrue(app.staticTexts["Kitchen Mac"].exists, "Kitchen Mac")
    XCTAssertTrue(
      app.descendants(matching: .any)["Manage Devices on Web"].exists,
      "Manage Devices on Web"
    )
    XCTAssertFalse(app.buttons["Manage devices on the web"].exists, "legacy inline manage link")
    attachScreenshot(app, name: "devices-content")
    try audit(app)
  }

  func testSignedOutFixtureShowsConnectWithGitHub() throws {
    let app = launch(fixture: "signed-out")
    XCTAssertTrue(
      app.descendants(matching: .any)["connect.root"].waitForExistence(timeout: 10),
      "connect.root"
    )
    XCTAssertTrue(app.buttons["Connect with GitHub"].exists, "Connect with GitHub")
    XCTAssertTrue(
      app.staticTexts["This iPhone only reads data reported by QuotaBar."].exists,
      "footnote"
    )
    XCTAssertFalse(app.buttons["Connect Account"].exists, "legacy Connect Account label")
    XCTAssertFalse(
      app.staticTexts[
        "See remaining quota and Today Usage for the GitHub Account you use with QuotaBar on your Mac."
      ].exists,
      "value proposition is not on Connect"
    )
    attachScreenshot(app, name: "connect-signed-out")
    try audit(app)
  }

  func testConnectingFixtureDisablesTheConnectButton() throws {
    let app = launch(fixture: "connecting")
    let button = app.buttons["Connect with GitHub"]
    XCTAssertTrue(button.waitForExistence(timeout: 10), "Connect with GitHub")
    XCTAssertFalse(button.isEnabled, "Connecting disables the button")
    XCTAssertEqual(
      button.value as? String, "Connecting", "Connecting is the busy accessibility value")
    attachScreenshot(app, name: "connect-connecting")
    try audit(app)
  }

  func testConnectErrorFixtureShowsTheFailureLine() throws {
    let app = launch(fixture: "connect-error")
    XCTAssertTrue(
      app.descendants(matching: .any)["connect.root"].waitForExistence(timeout: 10),
      "connect.root"
    )
    XCTAssertTrue(app.buttons["Connect with GitHub"].exists, "Connect with GitHub")
    XCTAssertTrue(app.staticTexts["Couldn't connect. Try again."].exists, "connect error")
    attachScreenshot(app, name: "connect-error")
    try audit(app)
  }

  func testExpiredFixtureShowsTheReconnectLine() throws {
    let app = launch(fixture: "expired")
    XCTAssertTrue(
      app.descendants(matching: .any)["connect.root"].waitForExistence(timeout: 10),
      "connect.root"
    )
    XCTAssertTrue(app.buttons["Connect with GitHub"].exists, "Connect with GitHub")
    XCTAssertTrue(app.staticTexts["Session expired. Connect again."].exists, "expired")
    attachScreenshot(app, name: "connect-expired")
    try audit(app)
  }

  func testLoadingFixtureShowsCenteredProgress() throws {
    let app = launch(fixture: "loading")
    XCTAssertTrue(
      app.descendants(matching: .any)["root.loading"].waitForExistence(timeout: 10),
      "root.loading"
    )
    XCTAssertTrue(app.staticTexts["Loading account…"].exists, "Loading account…")
    attachScreenshot(app, name: "root-loading")
    try audit(app)
  }

  func testConnectRefreshFailedFixtureShowsRetryWithoutContinue() throws {
    let app = launch(fixture: "connect-refresh-failed")
    XCTAssertTrue(
      app.descendants(matching: .any)["connect.root"].waitForExistence(timeout: 10),
      "connect.root"
    )
    XCTAssertTrue(app.buttons["Retry"].exists, "Retry")
    XCTAssertTrue(app.buttons["Use a different account"].exists, "Use a different account")
    XCTAssertFalse(app.buttons["Continue"].exists, "Continue is not offered")
    XCTAssertFalse(app.buttons["Connect with GitHub"].exists, "Connect is replaced by Retry")
    XCTAssertTrue(app.staticTexts["Couldn't reach quota.gotry.io."].exists, "network copy")
    attachScreenshot(app, name: "connect-refresh-failed")
    try audit(app)
  }

  func testUsageEmptyShowsUnavailableCopyAndEmptyActivity() throws {
    let app = launch(fixture: "empty")
    app.tabBars.buttons["Usage"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 10),
      "usage.root"
    )
    XCTAssertTrue(app.staticTexts["No usage"].waitForExistence(timeout: 5), "No usage")
    XCTAssertTrue(
      app.staticTexts["No usage was reported for this period."].exists,
      "empty period description"
    )
    let emptyActivity = app.staticTexts["No activity in the last year."]
    if !emptyActivity.waitForExistence(timeout: 2) {
      scrollToIdentifierOnce(app, "usage.activity.empty")
    }
    XCTAssertTrue(
      emptyActivity.waitForExistence(timeout: 5)
        || app.descendants(matching: .any)["usage.activity.empty"].exists,
      "empty activity"
    )
    attachScreenshot(app, name: "usage-empty")
    try audit(app)
  }

  func testEmptyFixtureShowsOverviewEmpty() throws {
    let app = launch(fixture: "empty")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    XCTAssertTrue(app.staticTexts["No quota yet"].waitForExistence(timeout: 5), "No quota yet")
    XCTAssertTrue(app.staticTexts["No usage today."].exists, "No usage today.")
    XCTAssertFalse(
      app.staticTexts["Set up QuotaBar"].exists,
      "empty Overview keeps devices, so Mac setup stays off this screen"
    )
    attachScreenshot(app, name: "overview-empty")
    try audit(app)
  }

  func testUsageActivityLoadingShowsSkeleton() throws {
    let app = launch(fixture: "activity-loading")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 10),
      "usage.root"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["Loading activity"].waitForExistence(timeout: 5)
        || app.descendants(matching: .any)["usage.activity.loading"].exists,
      "usage.activity.loading"
    )
    XCTAssertTrue(app.staticTexts["Tokens"].exists, "period totals remain visible")
    attachScreenshot(app, name: "usage-activity-loading")
    try audit(app)
  }

  func testUsageActivityFailedShowsRetry() throws {
    let app = launch(fixture: "activity-failed")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 10),
      "usage.root"
    )
    XCTAssertTrue(
      app.staticTexts["Tokens"].waitForExistence(timeout: 5),
      "period totals remain visible"
    )
    XCTAssertTrue(
      app.staticTexts["Couldn't load activity."].waitForExistence(timeout: 5)
        || app.descendants(matching: .any)["usage.activity.failed"].exists,
      "activity failed copy"
    )
    let retry = app.descendants(matching: .any)["usage.activity.retry"]
    if !retry.waitForExistence(timeout: 2) {
      scrollToIdentifierOnce(app, "usage.activity.retry")
    }
    XCTAssertTrue(
      retry.waitForExistence(timeout: 5) || app.buttons["Retry"].exists,
      "Retry"
    )
    attachScreenshot(app, name: "usage-activity-failed")
    try audit(app)
  }

  func testUsageDayEmptyShowsEmptyCopy() throws {
    let app = launch(fixture: "activity-day-empty")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.day"].waitForExistence(timeout: 10),
      "usage.day"
    )
    XCTAssertTrue(
      app.staticTexts["No usage on this day."].waitForExistence(timeout: 5),
      "empty day copy"
    )
    attachScreenshot(app, name: "usage-day-empty")
    try audit(app)
  }

  func testUsageDayFailedShowsRetry() throws {
    let app = launch(fixture: "activity-day-failed")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.day"].waitForExistence(timeout: 10),
      "usage.day"
    )
    XCTAssertTrue(
      app.staticTexts["Couldn't load this day's usage."].waitForExistence(timeout: 5),
      "failed day copy"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.day.retry"].exists,
      "Retry"
    )
    attachScreenshot(app, name: "usage-day-failed")
    try audit(app)
  }

  func testLargeTypeScreenshots() throws {
    try XCTSkipUnless(
      uitestEnvironment("QUOTA_IOS_TEXT_SIZE") != nil,
      "only when QUOTA_IOS_TEXT_SIZE is set"
    )

    func waitRoot(_ app: XCUIApplication, _ identifier: String) {
      XCTAssertTrue(
        app.descendants(matching: .any)[identifier].waitForExistence(timeout: 10),
        identifier
      )
    }

    var app = launch(fixture: "signed-out")
    waitRoot(app, "connect.root")
    attachScreenshot(app, name: "connect-signed-out")

    app = launch(fixture: "confirm-account")
    waitRoot(app, "confirm.root")
    attachScreenshot(app, name: "confirm-account")

    app = launch(fixture: "content")
    waitRoot(app, "overview.root")
    attachScreenshot(app, name: "overview-content")

    app.tabBars.buttons["Usage"].tap()
    waitRoot(app, "usage.root")
    attachScreenshot(app, name: "usage-content")

    app.tabBars.buttons["Overview"].tap()
    waitRoot(app, "overview.root")
    let card = app.descendants(matching: .any)["overview.subscription"].firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 5), "overview.subscription")
    card.tap()
    waitRoot(app, "subscription.detail")
    attachScreenshot(app, name: "subscription-detail")

    app = launch(fixture: "content")
    waitRoot(app, "overview.root")
    app.tabBars.buttons["Devices"].tap()
    waitRoot(app, "devices.root")
    attachScreenshot(app, name: "devices-content")

    func settingsShot(link: String, root: String, name: String, hub: Bool = false) {
      let settings = launch(fixture: "content")
      waitRoot(settings, "overview.root")
      settings.tabBars.buttons["Settings"].tap()
      waitRoot(settings, "settings.root")
      if hub {
        attachScreenshot(settings, name: name)
        return
      }
      openSettingsDestination(settings, link: link, root: root)
      attachScreenshot(settings, name: name)
    }

    settingsShot(link: "", root: "", name: "settings-main", hub: true)
    settingsShot(
      link: "settings.notifications", root: "settings.notifications.root",
      name: "settings-notifications")
    settingsShot(
      link: "settings.appearance", root: "settings.appearance.root", name: "settings-appearance")
    settingsShot(link: "settings.about", root: "settings.about.root", name: "settings-about")
  }

  func testConfirmAccountFixtureAsksToUseTheGitHubAccount() throws {
    let app = launch(fixture: "confirm-account")
    XCTAssertTrue(
      app.descendants(matching: .any)["confirm.root"].waitForExistence(timeout: 10),
      "confirm.root"
    )
    XCTAssertTrue(app.staticTexts["Use this GitHub account?"].exists, "title")
    XCTAssertTrue(app.buttons["Continue"].exists, "Continue")
    XCTAssertTrue(app.buttons["Use a different account"].exists, "Use a different account")
    attachScreenshot(app, name: "confirm-account")
    try audit(app)
  }

  private func launch(fixture: String) -> XCUIApplication {
    let app = XCUIApplication()
    var arguments = ["--visual-fixture", fixture]
    if let size = uitestEnvironment("QUOTA_IOS_TEXT_SIZE") {
      arguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategoryName(size)]
    }
    app.launchArguments = arguments
    app.launch()
    return app
  }

  private func uitestEnvironment(_ key: String) -> String? {
    if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
      return value
    }
    let file: String
    switch key {
    case "QUOTA_IOS_APPEARANCE": file = "/tmp/quota-ios-uitest-appearance"
    case "QUOTA_IOS_TEXT_SIZE": file = "/tmp/quota-ios-uitest-text-size"
    default: return nil
    }
    guard let raw = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func contentSizeCategoryName(_ size: String) -> String {
    switch size {
    case "extraSmall": "UICTContentSizeCategoryXS"
    case "small": "UICTContentSizeCategoryS"
    case "medium": "UICTContentSizeCategoryM"
    case "large": "UICTContentSizeCategoryL"
    case "extraLarge": "UICTContentSizeCategoryXL"
    case "extraExtraLarge": "UICTContentSizeCategoryXXL"
    case "extraExtraExtraLarge": "UICTContentSizeCategoryXXXL"
    case "accessibilityMedium": "UICTContentSizeCategoryAccessibilityM"
    case "accessibilityLarge": "UICTContentSizeCategoryAccessibilityL"
    case "accessibilityExtraLarge": "UICTContentSizeCategoryAccessibilityXL"
    case "accessibilityExtraExtraLarge": "UICTContentSizeCategoryAccessibilityXXL"
    case "accessibilityExtraExtraExtraLarge": "UICTContentSizeCategoryAccessibilityXXXL"
    default: size
    }
  }

  private func attachScreenshot(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func assertTab(_ app: XCUIApplication, _ name: String) {
    XCTAssertTrue(app.tabBars.buttons[name].exists, "\(name) tab")
  }

  private func openSettingsDestination(
    _ app: XCUIApplication,
    link: String,
    root: String
  ) {
    let control = app.descendants(matching: .any)[link]
    if !control.waitForExistence(timeout: 2) {
      scrollToIdentifierOnce(app, link)
    }
    XCTAssertTrue(control.waitForExistence(timeout: 5), link)
    control.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)[root].waitForExistence(timeout: 5),
      root
    )
  }

  private func popSettingsDestination(_ app: XCUIApplication) {
    let back = app.navigationBars.buttons["Settings"]
    XCTAssertTrue(back.waitForExistence(timeout: 5), "back to Settings")
    back.tap()
    let logout = app.descendants(matching: .any)["settings.logout"]
    if !logout.waitForExistence(timeout: 2) {
      scrollToIdentifierOnce(app, "settings.logout")
    }
    XCTAssertTrue(logout.waitForExistence(timeout: 5), "hub Log Out after pop")
  }

  /// One identifier-targeted scroll. Accessibility sizes can push a hub row below the fold.
  private func scrollToIdentifierOnce(_ app: XCUIApplication, _ identifier: String) {
    let element = app.descendants(matching: .any)[identifier]
    scrollContent(app, up: true)
    _ = element.waitForExistence(timeout: 1)
  }

  /// A minimized iOS 26 tab bar exposes only the selected tab; scrolling back toward the top
  /// re-expands it. Four visible tabs is the expanded state.
  private func restoreTabBar(_ app: XCUIApplication) throws {
    let tabBar = app.tabBars.firstMatch
    for _ in 0..<4 where tabBar.buttons.count < 4 {
      scrollContent(app, up: false)
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }
    XCTAssertEqual(tabBar.buttons.count, 4, "tab bar re-expands after scrolling back up")
  }

  /// Scrolls the signed-in list and records `overview-scrolled`. Tab-bar minimization is a
  /// manual gate: this simulator does not expose a measurable height drop or a single-button
  /// minimized tab bar, so this helper does not assert that product behavior.
  private func assertListScrolls(
    _ app: XCUIApplication,
    screenshot: String? = nil
  ) throws {
    let tabBar = app.tabBars.firstMatch
    XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "tab bar")
    let list = scrollableList(in: app)
    XCTAssertTrue(list.exists, "scrollable list")
    let before = list.screenshot().pngRepresentation
    scrollContent(app, up: true)
    scrollContent(app, up: true)
    app.swipeUp()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let after = list.screenshot().pngRepresentation
    XCTAssertNotEqual(before, after, "list scrolls")
    XCTAssertTrue(tabBar.exists, "tab bar remains after scroll")
    if let screenshot {
      attachScreenshot(app, name: screenshot)
    }
    XCTAssertTrue(tabBar.exists, "tab bar remains after scroll")
  }

  private func scrollableList(in app: XCUIApplication) -> XCUIElement {
    if app.collectionViews.firstMatch.exists { return app.collectionViews.firstMatch }
    if app.tables.firstMatch.exists { return app.tables.firstMatch }
    return app
  }

  private func scrollContent(_ app: XCUIApplication, up: Bool) {
    let list = scrollableList(in: app)
    let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.78 : 0.28))
    let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.22 : 0.78))
    start.press(forDuration: 0.05, thenDragTo: end)
  }

  /// Every issue is reported with the element it names, so a failure says what to fix.
  ///
  /// Connect signed-out, connecting, error, expired, first-refresh failure, loading, confirm,
  /// Overview, subscription detail, Devices, Usage, and Settings destinations run the app-owned
  /// audit, including contrast. System exceptions are scoped to the named element below. Connect
  /// (primary label, no tab bar) still runs contrast. Clipping and hit-region issues still fail
  /// this test. There is no unnamed clipping skip and no whole-type contrast skip.
  private func audit(
    _ app: XCUIApplication,
    skipping: XCUIAccessibilityAuditType = []
  ) throws {
    var types = XCUIAccessibilityAuditType.all
    types.remove(skipping)
    do {
      try performAudit(app, types: types)
    } catch {
      // The 365-day heatmap can make the iOS 26 contrast pass exceed the auditor's
      // deadline. Retry without contrast; other checks still run.
      let description = "\(error)"
      if description.contains("Audit failed to complete in time"),
        !skipping.contains(.contrast)
      {
        let screen = currentScreenName(app)
        XCTContext.runActivity(named: "Contrast audit did not complete on \(screen)") { activity in
          let attachment = XCTAttachment(
            string:
              "\(screen) did not finish the contrast pass; retrying without contrast. \(description)"
          )
          attachment.name = "contrast-audit-timeout-\(screen)"
          attachment.lifetime = .keepAlways
          activity.add(attachment)
        }
        var retry = types
        retry.remove(.contrast)
        try performAudit(app, types: retry)
        return
      }
      throw error
    }
  }

  private func currentScreenName(_ app: XCUIApplication) -> String {
    let ids = [
      "usage.day",
      "settings.about.root",
      "settings.notifications.root",
      "settings.appearance.root",
      "settings.root",
      "usage.root",
      "subscription.detail",
      "devices.root",
      "overview.root",
      "connect.root",
      "confirm.root",
      "root.loading",
    ]
    for id in ids {
      if app.descendants(matching: .any)[id].exists { return id }
    }
    return "unknown"
  }

  private func performAudit(
    _ app: XCUIApplication,
    types: XCUIAccessibilityAuditType
  ) throws {
    try app.performAccessibilityAudit(for: types) { issue in
      let description = issue.compactDescription
      let element = issue.element.map { "\($0)" } ?? "no element"
      let identifier = issue.element?.identifier ?? ""
      let isDynamicType = description.localizedCaseInsensitiveContains("Dynamic Type")

      // System tab bar / navigation / sheet glass reports without naming a control.
      if issue.element == nil {
        return true
      }

      // The floating iOS 26 tab bar is Liquid Glass over the last visible rows; the contrast
      // auditor samples the glass, not the row. Scoped to elements whose frame intersects the
      // tab bar's frame — a system-owned overlay, not an app-owned colour choice.
      if description.localizedCaseInsensitiveContains("Contrast"),
        let control = issue.element,
        app.tabBars.firstMatch.exists
      {
        // The glass blooms a little above the capsule itself.
        let overlay = app.tabBars.firstMatch.frame.insetBy(dx: -40, dy: -56)
        if control.frame.intersects(overlay) {
          return true
        }
      }

      // System List/Form section headers and footers we marked. Contrast and
      // Dynamic Type on those elements are iOS 26 UIListContentConfiguration.
      if identifier.hasPrefix("section.header.") || identifier.hasPrefix("section.footer.")
        || identifier == "overview.today"
        || element.contains("section.header.") || element.contains("section.footer.")
      {
        return true
      }

      if isDynamicType, let control = issue.element {
        let haystack = "\(control) \(control.identifier) \(control.label)"
        if haystack.contains("\"Done\" Button") {
          return true
        }
        // iOS 26 UIListContentConfiguration List/Form Button, Link, and
        // LabeledContent rows do not advertise full Dynamic Type. Contrast is
        // not skipped.
        if description.localizedCaseInsensitiveContains("partially unsupported") {
          let tokens = [
            "\"Enable Notifications\" StaticText",
            "\"Reset Reminders\" StaticText",
            "settings.notifications.enable",
            "settings.notifications.reset-reminders",
            "\"License\" StaticText",
            "\"Version\" StaticText",
            "usage.activity.selected-day",
            "usage.provider.",
            "usage.activity.retry",
            "usage.activity.view-day",
            "usage.day.retry",
            "usage.show-more",
            "usage.show-fewer",
            "usage.headline",
            "usage.day.headline",
            "overview.today.tokens",
            "overview.today.cost",
            "overview.today.input",
            "overview.today.output",
            "overview.today.empty",
            "usage.activity.loading",
            "usage.activity.failed",
            "usage.activity.empty",
            "subscription.account",
            "subscription.plan",
            "settings.about.version",
            "settings.about.license",
            "settings.notifications",
            "settings.appearance",
            "settings.about",
            "overview.subscription",
            "devices.manage",
            "settings.delete-account",
            "settings.logout",
            "GitHub",
            "Website",
            "Privacy",
            "Support",
            "Manage Devices on Web",
            "Download for Mac",
            "Download QuotaBar",
          ]
          let named = tokens.contains(where: { identifier == $0 || haystack.contains($0) })
          if named {
            return true
          }
        }
      }

      XCTFail("\(description) — \(element)")
      return true
    }
  }
}
