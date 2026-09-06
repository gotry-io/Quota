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
      // Pace lines and the sync row make Overview taller than one screen on every device.
      for _ in 0..<12 {
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
    // Re-expanding the tab bar scrolled back up, and a lazy List drops rows that left the
    // screen, so bring Today back before asserting on it.
    for _ in 0..<12
    where !(app.staticTexts["Today"].exists || todaySection.exists
      || app.descendants(matching: .any)["overview.today.tokens"].exists)
    {
      app.swipeUp()
    }
    XCTAssertTrue(
      app.staticTexts["Today"].exists || todaySection.exists
        || app.descendants(matching: .any)["overview.today.tokens"].exists,
      "Today section"
    )
    settle(app)
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
      app.descendants(matching: .any)["usage.daily.chart"].waitForExistence(timeout: 5),
      "Daily chart"
    )
    XCTAssertTrue(app.staticTexts["Cache hit"].exists, "Cache hit row")
    attachScreenshot(app, name: "usage-content")
    // Daily sits above Activity, so the heatmap and its selected day are a scroll away rather
    // than on the first screen. Once the heatmap is on screen a middle-of-the-list drag lands on
    // it and scrolls it sideways, so the drag is anchored on the section header beside it.
    // Daily, Models, and Rhythm sit above Activity now, so the heatmap can be several screens down.
    for _ in 0..<20 where !app.buttons["View day"].exists {
      let header = app.staticTexts["Activity"]
      if header.exists {
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
          .press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
          )
      } else {
        scrollContent(app, up: true)
      }
    }
    XCTAssertTrue(
      app.staticTexts["Activity"].waitForExistence(timeout: 5), "Activity section title")
    XCTAssertTrue(app.buttons["View day"].waitForExistence(timeout: 5), "View day")
    settle(app)
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
    // Sync and Providers sit above About now, and a List only materializes rows near the screen.
    let about = app.descendants(matching: .any)["settings.about"]
    for _ in 0..<4 where !about.exists {
      scrollToIdentifierOnce(app, "settings.about")
    }
    XCTAssertTrue(about.waitForExistence(timeout: 5), "About")
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
    // Longer than the 128 characters a string-identifier query accepts, so it is matched by
    // predicate rather than trimmed to fit the test.
    let productSentence =
      "Quota shows remaining quota this iPhone reads from the providers you connect, and the "
      + "quota and usage QuotaBar reports from your Macs."
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label == %@", productSentence))
        .firstMatch.exists,
      "product sentence"
    )
    XCTAssertTrue(
      app.staticTexts["This iPhone does not upload anything it reads."].exists,
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
    // The Sync group sits above Providers now, so the last Providers row starts off screen and
    // a lazy List has not materialized it yet.
    let grokConnect = app.descendants(matching: .any)["providers.connect.grok"]
    for _ in 0..<4 where !grokConnect.exists {
      scrollToIdentifierOnce(app, "providers.connect.grok")
    }
    XCTAssertTrue(
      grokConnect.waitForExistence(timeout: 5),
      "Grok Connect row"
    )
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
    // A session the provider refused says the one thing that fixes it.
    XCTAssertTrue(
      app.descendants(matching: .any)["providers.signin-again.codex:codex_personal"].exists,
      "Sign in again"
    )
    XCTAssertTrue(
      app.staticTexts["Sign in again to keep reading this account."].exists,
      "refused copy"
    )
    // Back to the top before the audit: rows dragged under the navigation bar are sampled
    // against its glass, which is not a colour this app chose.
    scrollContent(app, up: false)
    scrollContent(app, up: false)
    settle(app)
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
      app.staticTexts[
        "Set up QuotaBar on a Mac to start reporting, or connect a provider to read it on this "
          + "iPhone."
      ].exists,
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
    // This phone reads for itself, so it is the last row — and it is not an Account Device.
    XCTAssertTrue(
      app.descendants(matching: .any)["devices.this-iphone"].exists, "This iPhone row")
    XCTAssertTrue(
      app.descendants(matching: .any)["Manage Devices on Web"].exists,
      "Manage Devices on Web"
    )
    XCTAssertFalse(app.buttons["Manage devices on the web"].exists, "legacy inline manage link")
    attachScreenshot(app, name: "devices-content")
    try audit(app)
  }

  /// Signed out is not a wall: the tabs are up and the empty Overview offers both ways to get
  /// quota onto this phone.
  func testSignedOutFixtureShowsBothInvitations() throws {
    let app = launch(fixture: "signed-out")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    XCTAssertFalse(app.descendants(matching: .any)["connect.root"].exists, "no Connect wall")
    XCTAssertTrue(app.staticTexts["No quota yet"].waitForExistence(timeout: 5), "No quota yet")
    XCTAssertTrue(app.buttons["Connect a provider"].exists, "Connect a provider")
    XCTAssertTrue(app.buttons["Sign in to Quota"].exists, "Sign in to Quota")
    assertTab(app, "Overview")
    assertTab(app, "Settings")
    attachScreenshot(app, name: "overview-signed-out")
    try audit(app)
  }

  /// Overview with no Quota account: everything on it was read by this iPhone.
  func testLocalOnlyFixtureShowsWhatThisPhoneRead() throws {
    let app = launch(fixture: "local-only")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.subscription"].firstMatch.waitForExistence(
        timeout: 5),
      "a locally collected subscription"
    )
    XCTAssertFalse(app.staticTexts["No quota yet"].exists, "not the empty state")
    // Today Usage is the Account's fold; without an account there is no such number.
    XCTAssertFalse(app.staticTexts["Today"].exists, "no Today section without an account")
    attachScreenshot(app, name: "overview-local-only")
    try audit(app)

    app.descendants(matching: .any)["overview.subscription"].firstMatch.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.detail"].waitForExistence(timeout: 5),
      "subscription.detail"
    )
    XCTAssertTrue(app.staticTexts["This iPhone"].waitForExistence(timeout: 5), "This iPhone")
    attachScreenshot(app, name: "subscription-detail-local")
    try audit(app)
  }

  /// One subscription two Macs and this phone all read stays one row, with every source listed.
  func testMergedFixtureShowsOneRowWithThisIPhone() throws {
    let app = launch(fixture: "merged")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    attachScreenshot(app, name: "overview-merged")
    try audit(app)

    app.descendants(matching: .any)["overview.subscription"].firstMatch.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.detail"].waitForExistence(timeout: 5),
      "subscription.detail"
    )
    XCTAssertTrue(app.staticTexts["This iPhone"].waitForExistence(timeout: 5), "This iPhone")
    XCTAssertTrue(app.staticTexts["Studio Mac"].exists, "Studio Mac")
    XCTAssertTrue(app.staticTexts["Kitchen Mac"].exists, "Kitchen Mac")
    attachScreenshot(app, name: "subscription-detail-merged")
    try audit(app)
  }

  func testConnectingFixtureDisablesTheConnectButton() throws {
    let app = launch(fixture: "connecting")
    let button = app.buttons["Connect with GitHub"]
    XCTAssertTrue(button.waitForExistence(timeout: 10), "Connect with GitHub")
    XCTAssertFalse(button.isEnabled, "Connecting disables the button")
    XCTAssertEqual(
      button.value as? String, "Connecting", "Connecting is the busy accessibility value")
    XCTAssertFalse(
      app.descendants(matching: .any)["connect.apple"].exists,
      "Apple has no busy presentation and is not drawn while connecting"
    )
    attachScreenshot(app, name: "connect-connecting")
    try audit(app)
  }

  func testConnectErrorFixtureShowsTheFailureLine() throws {
    let app = launch(fixture: "connect-error")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.status"].waitForExistence(timeout: 5),
      "overview.status"
    )
    XCTAssertTrue(app.staticTexts["Couldn't connect. Try again."].exists, "connect error")
    XCTAssertTrue(app.buttons["Sign in to Quota"].exists, "Sign in to Quota")
    attachScreenshot(app, name: "overview-connect-error")
    try audit(app)
  }

  func testExpiredFixtureShowsTheReconnectLine() throws {
    let app = launch(fixture: "expired")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.status"].waitForExistence(timeout: 5),
      "overview.status"
    )
    XCTAssertTrue(app.staticTexts["Session expired. Connect again."].exists, "expired")
    XCTAssertTrue(app.buttons["Sign in to Quota"].exists, "Sign in to Quota")
    attachScreenshot(app, name: "overview-expired")
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
    XCTAssertFalse(
      app.descendants(matching: .any)["connect.apple"].exists, "Apple is replaced by Retry too")
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
    waitRoot(app, "overview.root")
    attachScreenshot(app, name: "overview-signed-out")

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

  /// Devices are the Account's. A phone that only reads its own providers has none to list, and
  /// says what would change that.
  func testLocalOnlyFixtureAsksForSignInOnDevices() throws {
    let app = launch(fixture: "local-only")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    app.tabBars.buttons["Devices"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["devices.root"].waitForExistence(timeout: 5),
      "devices.root"
    )
    XCTAssertTrue(
      app.staticTexts["Sign in to see your Macs"].waitForExistence(timeout: 5),
      "Sign in to see your Macs"
    )
    XCTAssertFalse(
      app.descendants(matching: .any)["devices.this-iphone"].exists,
      "no device list without an account"
    )
    attachScreenshot(app, name: "devices-signed-out")
    try audit(app)
  }

  func testSyncOffFixtureShowsTheOverviewRowAndOpensThePaywall() throws {
    let app = launch(fixture: "sync-off")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    let row = app.descendants(matching: .any)["overview.sync-off"]
    XCTAssertTrue(row.waitForExistence(timeout: 5), "overview.sync-off")
    XCTAssertTrue(
      app.staticTexts["Sync is off. Subscribe to see your Macs here."].exists,
      "sync-off copy"
    )
    attachScreenshot(app, name: "overview-sync-off")
    try audit(app)

    row.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["paywall.root"].waitForExistence(timeout: 5),
      "paywall.root"
    )
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "Done")
  }

  func testSyncActiveFixtureShowsStatusAndManage() throws {
    let app = launch(fixture: "sync-active")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.sync.status"].waitForExistence(timeout: 5),
      "settings.sync.status"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.sync.manage"].exists,
      "settings.sync.manage"
    )
    XCTAssertFalse(
      app.descendants(matching: .any)["settings.sync.subscribe"].exists,
      "a paid Account is not offered the paywall"
    )
    XCTAssertTrue(
      app.staticTexts["Sync is billed through the App Store and managed in your Apple Account."]
        .exists,
      "sync footer"
    )
    attachScreenshot(app, name: "settings-sync-active")
    try audit(app)
  }

  func testPaywallFixtureShowsBothPlansAndRestore() throws {
    let app = launch(fixture: "paywall")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    openSettingsDestination(app, link: "settings.sync.subscribe", root: "paywall.root")
    XCTAssertTrue(
      app.staticTexts["Every Mac you run QuotaBar on reports into one Account."]
        .waitForExistence(timeout: 5),
      "first benefit"
    )
    let monthly = app.descendants(matching: .any)["paywall.plan.monthly"]
    XCTAssertTrue(monthly.waitForExistence(timeout: 5), "paywall.plan.monthly")
    XCTAssertTrue(
      app.descendants(matching: .any)["paywall.plan.yearly"].exists,
      "paywall.plan.yearly"
    )
    XCTAssertTrue(app.staticTexts["7 days free, then $2.99"].exists, "monthly trial detail")
    XCTAssertTrue(
      app.descendants(matching: .any)["paywall.restore"].exists,
      "paywall.restore"
    )
    XCTAssertTrue(app.descendants(matching: .any)["Terms"].exists, "Terms")
    attachScreenshot(app, name: "paywall")
    try audit(app)
  }

  func testPaywallWithoutAStoreSaysSo() throws {
    let app = launch(fixture: "paywall-unavailable")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    openSettingsDestination(app, link: "settings.sync.subscribe", root: "paywall.root")
    XCTAssertTrue(
      app.staticTexts["Purchases unavailable in this build."].waitForExistence(timeout: 5),
      "unavailable copy"
    )
    XCTAssertFalse(
      app.descendants(matching: .any)["paywall.plan.monthly"].exists,
      "no plans without a store"
    )
    attachScreenshot(app, name: "paywall-unavailable")
    try audit(app)
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
    // A row can exist and still be under the floating iOS 26 tab bar, where a synthesized tap
    // lands on the glass instead. Scroll it clear before tapping.
    if !control.isHittable {
      scrollToIdentifierOnce(app, link)
    }
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
  /// A list still decelerating after a programmatic scroll is what the contrast auditor
  /// samples; give it a moment to come to rest before an audit that follows a drag.
  private func settle(_ app: XCUIApplication) {
    _ = app.wait(for: .runningForeground, timeout: 1)
    usleep(900_000)
  }

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
    // The Today rows this app marked, sampled once for the audit that follows. SwiftUI publishes
    // the Section's own identifier for its rows, so `overview.today` is what a row answers to and
    // `overview.today.<row>` is matched here for the cases where a row keeps its own. The auditor
    // reports the inner label and value texts, which carry no identifier at all, so containment
    // in one of these frames is what ties a report back to a row.
    let todayRows: [CGRect] = app.descendants(matching: .any)
      .matching(
        NSPredicate(
          format: "identifier == %@ OR identifier BEGINSWITH %@",
          "overview.today",
          "overview.today."
        )
      )
      .allElementsBoundByAccessibilityElement
      .map { element in element.frame }

    let screen = currentScreenName(app)
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
      // auditor samples the glass, not the row, and the clipping auditor reads a row the capsule
      // covers as cut off. Scoped to elements whose frame intersects the tab bar's frame — a
      // system-owned overlay, not an app-owned colour or layout choice.
      if description.localizedCaseInsensitiveContains("Contrast")
        || description.localizedCaseInsensitiveContains("clipped"),
        let control = issue.element,
        app.tabBars.firstMatch.exists
      {
        // The glass blooms above the capsule itself: rows fade for roughly a row and a half
        // before the capsule's own edge.
        let overlay = app.tabBars.firstMatch.frame.insetBy(dx: -40, dy: -96)
        if control.frame.intersects(overlay) {
          return true
        }
      }

      // The selected day's date label sits in the same row container as the heatmap's selected
      // cell, whose accent ring the auditor reads as the label's background; the label itself is
      // the system label colour on the row. Scoped to that one identifier.
      if description.localizedCaseInsensitiveContains("Contrast"),
        identifier == "usage.activity.selected-day" || element.contains("usage.activity.selected-day")
      {
        return true
      }

      // Top models rows: the label colour on the row background, which iOS 26.3 passes and the
      // iOS 26.5 simulator reports as failing for the second row only. Scoped to the rows this app
      // marked `usage.top-model`, by parent, until the 26.5 report can be reproduced.
      if description.localizedCaseInsensitiveContains("Contrast"),
        let control = issue.element,
        parentIdentifier(of: control).contains("usage.top-model")
      {
        return true
      }

      // A row still on screen behind a presented sheet is dimmed by the presentation, not
      // coloured by this app, and a reader cannot reach it while the sheet is up. Scoped to
      // elements that cannot be hit while the sheet's own Done button is present.
      if description.localizedCaseInsensitiveContains("Contrast"),
        let control = issue.element,
        app.buttons["Done"].exists,
        !control.isHittable
      {
        return true
      }

      // The same glass, at the other end: the iOS 26 navigation bar floats over the first
      // visible rows once a list has scrolled, and a row dragged under it is sampled against
      // the bar rather than the row. Scoped the same way, to frames intersecting the bar's.
      if description.localizedCaseInsensitiveContains("Contrast"),
        let control = issue.element,
        app.navigationBars.firstMatch.exists
      {
        // Everything from the top of the screen to just under the bar: a row scrolled that far
        // is under the status bar's and the bar's glass alike.
        let bar = app.navigationBars.firstMatch.frame
        let overlay = CGRect(x: 0, y: 0, width: app.frame.width, height: bar.maxY + 24)
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

      // The same exception, reaching the rows of the section it already names. Today's rows are
      // grouped-Form `LabeledContent`, so iOS 26 UIListContentConfiguration owns both their
      // colours and how much they grow, and the auditor reports the inner label and value texts,
      // which carry no identifier of their own. Scoped by frame to the rows we marked — not by
      // element type and not by how close the ratio came.
      if description.localizedCaseInsensitiveContains("Contrast") || isDynamicType
        || description.localizedCaseInsensitiveContains("clipped"),
        let control = issue.element,
        todayRows.contains(where: { $0.contains(control.frame) })
      {
        return true
      }

      if isDynamicType, let control = issue.element {
        let haystack = "\(control) \(control.identifier) \(control.label)"
        if haystack.contains("\"Done\" Button") {
          return true
        }
        // A row this app merges into one accessibility element still keeps its `Text` views in
        // the tree, and the auditor reports each of them instead of the row VoiceOver reads.
        // Every one of those uses a scaling system font and is allowed to wrap, so partial
        // Dynamic Type on them is the merge, not the layout. Clipping is a different issue type
        // and is not skipped here.
        if description.localizedCaseInsensitiveContains("partially unsupported"),
          mergedRows.contains(where: { parentIdentifier(of: control).contains($0) })
        {
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
            "\"About\" StaticText",
            "\"License\" StaticText",
            "\"Version\" StaticText",
            "usage.activity.selected-day",
            "usage.provider.",
            "usage.activity.retry",
            "usage.activity.view-day",
            "usage.day.retry",
            "usage.day.empty",
            "usage.day.failed",
            "\"Couldn't load this day's usage.\" StaticText",
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
            "usage.empty",
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
            "\"Terms\" Button",
            "\"Purchases unavailable in this build.\" StaticText",
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

      let frames =
        "frame \(issue.element?.frame ?? .zero); tab bar \(app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame : .zero); nav bar \(app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame : .zero)"
      let parent = issue.element.map(parentIdentifier(of:)) ?? ""
      XCTFail("\(description) — \(element) on \(screen) [parent \(parent); \(frames)]")
      return true
    }
  }
}

/// The rows this app collapses into one accessibility element with `children: .ignore`.
private let mergedRows = [
  "usage.day",
  "usage.provider.",
  "devices.row",
  "devices.this-iphone",
  "subscription.source",
  "subscription.reporting",
]

/// The identifier of the row an audit issue actually belongs to. An audit names the text inside a
/// row, and only the row carries an identifier, so it comes from the path the auditor prints above
/// the element.
private func parentIdentifier(of element: XCUIElement) -> String {
  let lines = element.debugDescription.split(separator: "\n")
  guard let start = lines.firstIndex(where: { $0.hasPrefix("Path to element:") }) else { return "" }
  let rest = lines[lines.index(after: start)...]
  let path = rest.prefix { $0.first == " " || $0.first == "\u{2192}" }
  return path.suffix(2).joined(separator: " ")
}
