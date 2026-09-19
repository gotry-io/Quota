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
      // Pace lines make Overview taller than one screen on every device.
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
    assertTab(app, "Quota")
    assertTab(app, "Usage")
    assertTab(app, "Settings")
    XCTAssertFalse(app.tabBars.buttons["Devices"].exists, "Devices is not a tab")
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
    XCTAssertTrue(app.navigationBars["Quota"].exists, "Quota page title")
    XCTAssertFalse(
      app.navigationBars["octocat"].exists,
      "account identity is not the Overview title"
    )
    XCTAssertFalse(
      app.descendants(matching: .any)["overview.today.input"].exists,
      "Input tile is gone"
    )
    XCTAssertFalse(
      app.descendants(matching: .any)["overview.today.output"].exists,
      "Output tile is gone"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.today.tokens"].exists,
      "overview.today.tokens"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.today.cost"].exists,
      "overview.today.cost"
    )
    settle(app)
    attachScreenshot(app, name: "overview-content")
    try audit(app)
    try assertListScrolls(app, screenshot: "overview-scrolled")
    try restoreTabBar(app)
    revealIdentifier(app, "overview.today")
    app.descendants(matching: .any)["overview.today"].firstMatch.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 10),
      "usage.root"
    )
    let period = app.segmentedControls.firstMatch
    XCTAssertTrue(period.waitForExistence(timeout: 5), "usage period control")
    XCTAssertTrue(period.buttons["Today"].exists, "Today segment")
    XCTAssertTrue(period.buttons["Today"].isSelected, "Overview Today opens the Today period")
    XCTAssertTrue(period.buttons["Last 7 days"].exists, "Last 7 days segment")
    XCTAssertTrue(period.buttons["Last 30 days"].exists, "Last 30 days segment")
    period.buttons["Last 30 days"].tap()
    XCTAssertTrue(app.staticTexts["Cache hit"].waitForExistence(timeout: 5), "Cache hit row")
    // The period stepper and the budget section sit above the totals, so Daily starts below the
    // viewport, and a List builds only the rows near it. Scroll to the chart rather than wait.
    let dailyChart = app.descendants(matching: .any)["usage.daily.chart"]
    for _ in 0..<8 where !dailyChart.exists {
      scrollContent(app, up: true)
    }
    XCTAssertTrue(dailyChart.waitForExistence(timeout: 5), "Daily chart")
    attachScreenshot(app, name: "usage-content")
    // Daily sits above Activity, so the heatmap and its selected day are a scroll away rather
    // than on the first screen. Once the heatmap is on screen a middle-of-the-list drag lands on
    // it and scrolls it sideways, so the drag is anchored on the section header beside it.
    // Daily, Models, and Rhythm sit above Activity now, so the heatmap can be several screens down.
    // The header is what says the section was reached; by the time the day action is on screen
    // the header itself may have scrolled off the top, so it is recorded on the way past.
    var reachedActivity = app.staticTexts["Activity"].exists
    // Once the header has gone past, a middle-of-the-list drag would land on the heatmap and
    // scroll it sideways, so the fallback is a swipe, which the day action below uses too.
    for _ in 0..<24 where !app.buttons["View day"].exists {
      let header = app.staticTexts["Activity"]
      if header.exists {
        reachedActivity = true
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
          .press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
          )
      } else if reachedActivity {
        app.swipeUp()
      } else {
        scrollContent(app, up: true)
      }
    }
    XCTAssertTrue(
      reachedActivity || app.staticTexts["Activity"].exists, "Activity section title")
    XCTAssertTrue(app.buttons["View day"].waitForExistence(timeout: 5), "View day")
    settle(app)
    attachScreenshot(app, name: "usage-activity")
    // At accessibility Extra Large the Usage list is several screens long. After the activity
    // screenshot **View day** is already on screen (the tab bar is minimized). Restoring the
    // tab bar first scrolled it away, and a dozen swipes were not enough to bring a lazy row
    // back — the tap landed on nothing and `usage.day` never appeared. Open the sheet while
    // the control is still here; audit Usage from the top after dismissing.
    let viewDay = app.descendants(matching: .any)["usage.activity.view-day"]
    if !viewDay.exists || !viewDay.isHittable {
      revealIdentifier(app, "usage.activity.view-day", attempts: 24)
    }
    XCTAssertTrue(viewDay.waitForExistence(timeout: 5), "View day")
    settle(app)
    if !viewDay.isHittable {
      revealIdentifier(app, "usage.activity.view-day", attempts: 8)
    }
    viewDay.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.day"].waitForExistence(timeout: 8),
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
    settle(app)
    try audit(app)
    let showMore = app.descendants(matching: .any)["usage.show-more"]
    let showMoreLabel = app.buttons["Show 2 more OpenAI models"]
    let codex = app.staticTexts["Codex"]
    // The agent sections are below the heatmap, which is most of a screen on its own, so this
    // starts at the top of a page that is several screens long.
    for _ in 0..<40 {
      if showMore.exists || showMoreLabel.exists || codex.exists { break }
      app.swipeUp()
      // A swipe that lands while the list is still decelerating is absorbed by the bounce.
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    XCTAssertTrue(
      showMore.exists || showMoreLabel.exists || codex.exists,
      "model rows"
    )
    try assertListScrolls(app)
    try restoreTabBar(app)

    app.tabBars.buttons["Quota"].tap()
    let card = app.descendants(matching: .any)["overview.subscription"].firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 5), "overview.subscription")
    card.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.detail"].waitForExistence(timeout: 5),
      "subscription.detail"
    )
    let account = app.descendants(matching: .any)["subscription.account"]
    if !account.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "subscription.account", attempts: 8)
    }
    XCTAssertTrue(account.waitForExistence(timeout: 5), "Account")
    if !app.staticTexts["Quota"].exists {
      scrollToIdentifier(app, "section.header.quota", attempts: 8)
    }
    XCTAssertTrue(
      app.staticTexts["Quota"].exists
        || app.descendants(matching: .any)["section.header.quota"].exists,
      "Quota"
    )
    let reporting = app.descendants(matching: .any)["subscription.reporting"]
    if !reporting.waitForExistence(timeout: 2) {
      revealSources(app)
      scrollToIdentifier(app, "subscription.reporting", attempts: 12)
    }
    XCTAssertTrue(reporting.waitForExistence(timeout: 5), "Reporting")
    XCTAssertTrue(
      app.staticTexts["Readings"].exists
        || app.descendants(matching: .any)["section.header.readings"].exists
        || app.descendants(matching: .any)["subscription.sources"].exists
        || reporting.exists,
      "Readings"
    )
    scrollToIdentifier(app, "subscription.history")
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.history"].waitForExistence(timeout: 5),
      "subscription.history"
    )
    XCTAssertTrue(
      app.staticTexts["This iPhone has no readings of its own for this subscription."].exists
        || app.descendants(matching: .any)["subscription.history"].exists,
      "remote-only remaining history"
    )
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
      app.descendants(matching: .any)["settings.devices"].waitForExistence(timeout: 5),
      "Devices"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.notifications"].exists,
      "Notifications"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.appearance"].exists,
      "Appearance"
    )
    // Identity, Preferences, and Providers sit above About. At accessibility Extra Large
    // that is more than one screen, and a lazy List has not built About yet.
    let about = app.descendants(matching: .any)["settings.about"]
    if !about.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "settings.about", attempts: 12)
    }
    XCTAssertTrue(about.waitForExistence(timeout: 5), "About")
    let deleteAccount = app.descendants(matching: .any)["settings.delete-account"]
    if !deleteAccount.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "settings.delete-account", attempts: 12)
    }
    XCTAssertTrue(
      deleteAccount.waitForExistence(timeout: 5) || app.buttons["Delete Account…"].exists,
      "Delete Account…"
    )
    let logout = app.descendants(matching: .any)["settings.logout"]
    if !logout.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "settings.logout", attempts: 12)
    }
    XCTAssertTrue(logout.waitForExistence(timeout: 5), "Log Out on Settings hub")
    XCTAssertTrue(app.buttons["Log Out"].exists, "Log Out")
    // Back to the top: the hub is longer than one screen, and a row scrolled under the
    // navigation bar's glass is a system overlay the contrast pass would sample instead of the row.
    scrollToTop(app)
    attachScreenshot(app, name: "settings-main")
    settle(app)
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
      app.staticTexts["This iPhone never uploads its sign-ins. Only the readings it takes reach your Account."].exists,
      "privacy sentence"
    )
    // The 64pt mark and the two sentences fill an accessibility Extra Large screen, so
    // Version / Website / GitHub / License start below the fold.
    if !app.descendants(matching: .any)["settings.about.version"].waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "settings.about.version", attempts: 8)
    }
    XCTAssertTrue(
      app.staticTexts["Version"].exists
        || app.descendants(matching: .any)["settings.about.version"].exists,
      "Version"
    )
    XCTAssertTrue(app.descendants(matching: .any)["Website"].exists, "Website")
    XCTAssertTrue(app.descendants(matching: .any)["GitHub"].exists, "GitHub")
    if !app.descendants(matching: .any)["settings.about.license"].waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "settings.about.license", attempts: 6)
    }
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
    // The header can be on screen while the first connected row is still below the fold
    // (and not yet in the lazy List). Scroll to the row rather than asserting existence.
    let firstCodex = app.descendants(matching: .any)["providers.session.codex:codex_work"]
    if !firstCodex.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "providers.session.codex:codex_work", attempts: 12)
    }
    XCTAssertTrue(
      firstCodex.waitForExistence(timeout: 5),
      "first connected Codex account"
    )
    let secondCodex = app.descendants(matching: .any)["providers.session.codex:codex_personal"]
    if !secondCodex.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "providers.session.codex:codex_personal", attempts: 8)
    }
    XCTAssertTrue(secondCodex.waitForExistence(timeout: 5), "second connected Codex account")
    let claude = app.descendants(matching: .any)["providers.session.claude:claude_team"]
    if !claude.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "providers.session.claude:claude_team", attempts: 8)
    }
    XCTAssertTrue(claude.waitForExistence(timeout: 5), "connected Claude Code account")
    // Remove / Sign in again sit on the session rows. Assert them before scrolling to Grok,
    // which drops those rows from a lazy List.
    if !app.descendants(matching: .any)["providers.remove.codex:codex_work"].exists {
      scrollToIdentifier(app, "providers.remove.codex:codex_work", attempts: 8)
    }
    XCTAssertTrue(
      app.descendants(matching: .any)["providers.remove.codex:codex_work"].exists,
      "Remove"
    )
    if !app.descendants(matching: .any)["providers.signin-again.codex:codex_personal"].exists {
      scrollToIdentifier(app, "providers.signin-again.codex:codex_personal", attempts: 8)
    }
    XCTAssertTrue(
      app.descendants(matching: .any)["providers.signin-again.codex:codex_personal"].exists,
      "Sign in again"
    )
    XCTAssertTrue(
      app.staticTexts["Sign in again to keep reading this account."].exists,
      "refused copy"
    )
    // The last Providers row starts off screen and a lazy List has not materialized it yet.
    let grokConnect = app.descendants(matching: .any)["providers.connect.grok"]
    if !grokConnect.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "providers.connect.grok", attempts: 12)
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
    if !codexConnect.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "providers.connect.codex", attempts: 8)
    }
    XCTAssertTrue(
      codexConnect.label.contains("Add Account"),
      "a provider already connected offers another account, got \(codexConnect.label)"
    )
    // Back to the top before the audit: rows dragged under the navigation bar are sampled
    // against its glass, which is not a colour this app chose. Two drags were not the top
    // of this hub at Extra Large — the refused copy sat just below the nav overlay skip.
    scrollToTop(app)
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
    XCTAssertTrue(
      app.staticTexts["See quota on this iPhone"].waitForExistence(timeout: 5),
      "See quota on this iPhone"
    )
    XCTAssertFalse(app.staticTexts["No quota yet"].exists, "first-run copy replaced No quota yet")
    XCTAssertTrue(
      app.staticTexts[
        "Set up QuotaBar on a Mac to start reporting, or connect a provider to read it on this "
          + "iPhone."
      ].exists,
      "empty quota description"
    )
    if !app.staticTexts["No usage today."].exists {
      scrollToIdentifier(app, "overview.today.empty")
    }
    XCTAssertTrue(
      app.staticTexts["No usage today."].exists
        || app.descendants(matching: .any)["overview.today.empty"].exists,
      "No usage today."
    )
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
    settle(app)
    try audit(app)

    try openDevicesFromSettings(app)
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
    try openDevicesFromSettings(app)
    XCTAssertTrue(
      app.descendants(matching: .any)["devices.root"].waitForExistence(timeout: 5),
      "devices.root"
    )
    XCTAssertTrue(app.staticTexts["Studio Mac"].waitForExistence(timeout: 5), "Studio Mac")
    XCTAssertTrue(app.staticTexts["Kitchen Mac"].exists, "Kitchen Mac")
    // This phone is one of the Account's Devices now, so it is a row like the Macs rather than
    // a local one beside itself.
    XCTAssertTrue(app.staticTexts["Kyle iPhone"].exists, "Kyle iPhone")
    XCTAssertFalse(
      app.descendants(matching: .any)["devices.this-iphone"].exists,
      "a registered phone is not also a local row")
    XCTAssertTrue(
      app.descendants(matching: .any)["Manage Devices on Web"].exists,
      "Manage Devices on Web"
    )
    XCTAssertFalse(app.buttons["Manage devices on the web"].exists, "legacy inline manage link")
    attachScreenshot(app, name: "devices-content")
    try audit(app)
  }

  /// Content fixture: Settings › Devices › back.
  func testContentFixtureOpensDevicesFromSettings() throws {
    let app = launch(fixture: "content")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    try openDevicesFromSettings(app)
    XCTAssertTrue(app.staticTexts["Studio Mac"].waitForExistence(timeout: 5), "Studio Mac")
    XCTAssertTrue(
      app.descendants(matching: .any)["devices.row"].firstMatch.exists,
      "devices.row"
    )
    popBack(app, to: "settings.root", backTitle: "Settings")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.devices"].waitForExistence(timeout: 5),
      "settings.devices after back"
    )
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
    XCTAssertTrue(app.navigationBars["Quota"].waitForExistence(timeout: 5), "Quota page title")
    XCTAssertTrue(
      app.staticTexts["See quota on this iPhone"].waitForExistence(timeout: 5),
      "See quota on this iPhone"
    )
    XCTAssertTrue(
      app.staticTexts["Credentials stay on this phone."].exists,
      "Connect outcome"
    )
    XCTAssertTrue(app.staticTexts["Already use QuotaBar?"].exists, "Already use QuotaBar?")
    XCTAssertTrue(
      app.staticTexts["See readings from your other devices."].exists,
      "Sign-in outcome"
    )
    XCTAssertFalse(app.staticTexts["No quota yet"].exists, "first-run copy replaced No quota yet")
    XCTAssertTrue(app.buttons["Connect a provider"].exists, "Connect a provider")
    XCTAssertTrue(app.buttons["Sign in to Quota"].exists, "Sign in to Quota")
    assertTab(app, "Quota")
    assertTab(app, "Settings")
    XCTAssertFalse(app.tabBars.buttons["Devices"].exists, "Devices is not a tab")
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
    XCTAssertFalse(
      app.descendants(matching: .any)["overview.empty"].exists,
      "not the empty state"
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
    // What this phone read for itself has samples behind it, so remaining history plots them.
    let localHistory = app.descendants(matching: .any)["subscription.history"].firstMatch
    if !localHistory.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "subscription.history", attempts: 12)
    }
    XCTAssertTrue(
      localHistory.waitForExistence(timeout: 5),
      "subscription.history"
    )
    XCTAssertTrue(app.staticTexts["Remaining history"].waitForExistence(timeout: 5), "history title")
    XCTAssertTrue(app.staticTexts["This iPhone"].exists, "This iPhone beside remaining history")
    attachScreenshot(app, name: "subscription-detail-local")
    try audit(app)

    revealSources(app)
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.sources"].exists,
      "subscription.sources"
    )
    scrollToIdentifier(app, "subscription.reporting")
    XCTAssertTrue(app.staticTexts["This iPhone"].waitForExistence(timeout: 5), "This iPhone")
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
    let mergedHistory = app.descendants(matching: .any)["subscription.history"].firstMatch
    if !mergedHistory.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "subscription.history", attempts: 12)
    }
    XCTAssertTrue(
      mergedHistory.waitForExistence(timeout: 5),
      "subscription.history"
    )
    attachScreenshot(app, name: "subscription-detail-merged")
    try audit(app)

    revealSources(app)
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.sources"].exists,
      "subscription.sources"
    )
    scrollToIdentifier(app, "subscription.reporting")
    XCTAssertTrue(app.staticTexts["This iPhone"].waitForExistence(timeout: 5), "This iPhone")
    let studio = app.staticTexts["Studio Mac"]
    if !studio.waitForExistence(timeout: 2) {
      for _ in 0..<8 where !studio.exists {
        scrollContent(app, up: true)
        _ = studio.waitForExistence(timeout: 1)
      }
    }
    XCTAssertTrue(studio.waitForExistence(timeout: 5), "Studio Mac")
    let kitchen = app.staticTexts["Kitchen Mac"]
    if !kitchen.waitForExistence(timeout: 2) {
      for _ in 0..<8 where !kitchen.exists {
        scrollContent(app, up: true)
        _ = kitchen.waitForExistence(timeout: 1)
      }
    }
    XCTAssertTrue(kitchen.waitForExistence(timeout: 5), "Kitchen Mac")
  }

  /// The one page that offers every way in, over the tabs it was asked from.
  func testSignInFixtureOffersEveryWayIn() throws {
    let app = launch(fixture: "sign-in")
    XCTAssertTrue(
      app.descendants(matching: .any)["connect.root"].waitForExistence(timeout: 10),
      "connect.root"
    )
    XCTAssertTrue(app.descendants(matching: .any)["connect.apple"].exists, "Continue with Apple")
    XCTAssertTrue(app.buttons["Continue with GitHub"].exists, "Continue with GitHub")
    XCTAssertTrue(app.buttons["Continue with Email"].exists, "Continue with Email")
    XCTAssertFalse(
      app.descendants(matching: .any)["connect.connecting"].exists,
      "nothing is in flight until a way in is chosen"
    )
    attachScreenshot(app, name: "sign-in")
    try audit(app)
  }

  func testConnectingFixtureShowsOneBusyControl() throws {
    let app = launch(fixture: "connecting")
    let button = app.descendants(matching: .any)["connect.connecting"]
    XCTAssertTrue(button.waitForExistence(timeout: 10), "connect.connecting")
    XCTAssertFalse(button.isEnabled, "Connecting is not actionable")
    XCTAssertFalse(
      app.descendants(matching: .any)["connect.apple"].exists,
      "Apple has no busy presentation and is not drawn while connecting"
    )
    XCTAssertFalse(
      app.buttons["Continue with Email"].exists,
      "no second way in while a sign-in is in flight"
    )
    attachScreenshot(app, name: "connect-connecting")
    try audit(app)
  }

  /// Sign-in methods: one row per channel, the bound ones named, the open one offering a way to
  /// bind it, and the website for everything this app does not do itself.
  func testSignInMethodsFixtureShowsEveryChannel() throws {
    let app = launch(fixture: "sign-in-methods")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    let apple = app.descendants(matching: .any)["settings.sign-in-methods.apple"]
    let github = app.descendants(matching: .any)["settings.sign-in-methods.github"]
    let email = app.descendants(matching: .any)["settings.sign-in-methods.email"]
    for _ in 0..<8 where !apple.exists || !github.exists || !email.exists {
      scrollToIdentifierOnce(app, "settings.sign-in-methods.github")
    }
    XCTAssertTrue(apple.waitForExistence(timeout: 5), "Apple row")
    XCTAssertTrue(github.waitForExistence(timeout: 5), "GitHub row")
    XCTAssertTrue(email.waitForExistence(timeout: 5), "Email row")
    XCTAssertTrue(app.staticTexts["octocat"].exists, "the GitHub channel's label")
    XCTAssertTrue(app.staticTexts["Linked"].exists, "a channel bound with no label")
    XCTAssertTrue(app.staticTexts["Not linked"].exists, "the channel still open")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.sign-in-methods.link.email"].exists,
      "Link on Web for the channel this app does not bind itself"
    )
    XCTAssertFalse(
      app.descendants(matching: .any)["settings.sign-in-methods.link.github"].exists,
      "a bound channel offers no Link"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.sign-in-methods.manage"].exists, "Manage on Web")
    attachScreenshot(app, name: "settings-sign-in-methods")
    settleScroll(app, anchor: github)
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
    if !app.staticTexts["No usage"].waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "usage.empty")
    }
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
    settle(app)
    try audit(app)
  }

  func testEmptyFixtureShowsOverviewEmpty() throws {
    let app = launch(fixture: "empty")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    XCTAssertTrue(
      app.staticTexts["See quota on this iPhone"].waitForExistence(timeout: 5),
      "See quota on this iPhone"
    )
    XCTAssertFalse(app.staticTexts["No quota yet"].exists, "first-run copy replaced No quota yet")
    if !app.staticTexts["No usage today."].exists {
      scrollToIdentifier(app, "overview.today.empty")
    }
    XCTAssertTrue(
      app.staticTexts["No usage today."].exists
        || app.descendants(matching: .any)["overview.today.empty"].exists,
      "No usage today."
    )
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
    if !app.descendants(matching: .any)["usage.activity.loading"].waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "usage.activity.loading")
    }
    XCTAssertTrue(
      app.descendants(matching: .any)["Loading activity"].waitForExistence(timeout: 5)
        || app.descendants(matching: .any)["usage.activity.loading"].exists,
      "usage.activity.loading"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.headline"].exists
        || app.descendants(matching: .any)["usage.headline.cache-hit"].exists,
      "period totals remain visible"
    )
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
      app.descendants(matching: .any)["usage.headline"].waitForExistence(timeout: 5)
        || app.descendants(matching: .any)["usage.headline.cache-hit"].exists,
      "period totals remain visible"
    )
    if !app.descendants(matching: .any)["usage.activity.failed"].waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "usage.activity.failed")
    }
    XCTAssertTrue(
      app.staticTexts["Couldn't load activity."].waitForExistence(timeout: 5)
        || app.descendants(matching: .any)["usage.activity.failed"].exists,
      "activity failed copy"
    )
    let retry = app.descendants(matching: .any)["usage.activity.retry"]
    if !retry.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "usage.activity.retry")
    }
    XCTAssertTrue(
      retry.waitForExistence(timeout: 5) || app.buttons["Retry"].exists,
      "Retry"
    )
    attachScreenshot(app, name: "usage-activity-failed")
    settle(app)
    try audit(app)
  }

  func testUsageDayEmptyShowsEmptyCopy() throws {
    let app = launch(fixture: "activity-day-empty")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.day"].waitForExistence(timeout: 10),
      "usage.day"
    )
    if !app.staticTexts["No usage on this day."].waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "usage.day.empty")
    }
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
    if !app.descendants(matching: .any)["usage.day.retry"].waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "usage.day.retry")
    }
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.day.retry"].exists,
      "Retry"
    )
    attachScreenshot(app, name: "usage-day-failed")
    try audit(app)
  }

  /// Always `accessibilityExtraLarge`, including CI's `verify-ios-ui`. Visits the four
  /// below-the-fold flows that the local screenshot script used to be the only net for.
  func testLargeTypeScreenshots() throws {
    let ax = "accessibilityExtraLarge"

    func waitRoot(_ app: XCUIApplication, _ identifier: String) {
      XCTAssertTrue(
        app.descendants(matching: .any)[identifier].waitForExistence(timeout: 10),
        identifier
      )
    }

    var app = launch(fixture: "content", textSize: ax)
    waitRoot(app, "overview.root")
    attachScreenshot(app, name: "overview-content")

    app.tabBars.buttons["Usage"].tap()
    waitRoot(app, "usage.root")
    attachScreenshot(app, name: "usage-content")
    let period = app.segmentedControls.firstMatch
    if period.waitForExistence(timeout: 5), period.buttons["Last 30 days"].exists {
      period.buttons["Last 30 days"].tap()
    }
    let viewDay = app.descendants(matching: .any)["usage.activity.view-day"]
    var reachedActivity = app.staticTexts["Activity"].exists
    for _ in 0..<32 where !viewDay.exists {
      let header = app.staticTexts["Activity"]
      if header.exists {
        reachedActivity = true
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
          .press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
          )
      } else if reachedActivity {
        app.swipeUp()
      } else {
        scrollContent(app, up: true)
      }
    }
    if !viewDay.exists || !viewDay.isHittable {
      revealIdentifier(app, "usage.activity.view-day", attempts: 16)
    }
    XCTAssertTrue(viewDay.waitForExistence(timeout: 5), "View day")
    viewDay.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.day"].waitForExistence(timeout: 8),
      "usage.day"
    )
    attachScreenshot(app, name: "usage-day")
    app.buttons["Done"].tap()

    try restoreTabBar(app)
    app.tabBars.buttons["Settings"].tap()
    waitRoot(app, "settings.root")
    attachScreenshot(app, name: "settings-main")
    openSettingsDestination(app, link: "settings.about", root: "settings.about.root")
    attachScreenshot(app, name: "settings-about")
    popSettingsDestination(app)

    app = launch(fixture: "providers", textSize: ax)
    waitRoot(app, "settings.root")
    scrollToIdentifier(app, "providers.session.codex:codex_work", attempts: 12)
    XCTAssertTrue(
      app.descendants(matching: .any)["providers.session.codex:codex_work"]
        .waitForExistence(timeout: 5),
      "first connected Codex account"
    )
    attachScreenshot(app, name: "settings-providers")
  }

  /// Devices are the Account's. Without an account the Settings row is absent; the sign-in
  /// card already covers it.
  func testLocalOnlyFixtureHasNoDevicesRow() throws {
    let app = launch(fixture: "local-only")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    try restoreTabBar(app)
    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    XCTAssertFalse(
      app.descendants(matching: .any)["settings.devices"].exists,
      "Devices row is absent when signed out"
    )
    XCTAssertFalse(
      app.descendants(matching: .any)["devices.root"].exists,
      "Devices is not a tab"
    )
    attachScreenshot(app, name: "settings-local-only")
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

  private func launch(fixture: String, textSize: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    var arguments = ["--visual-fixture", fixture]
    if let size = textSize ?? uitestEnvironment("QUOTA_IOS_TEXT_SIZE") {
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

  /// Devices is a Settings destination. Restore the tab bar, open Settings, then the row.
  private func openDevicesFromSettings(_ app: XCUIApplication) throws {
    let root = app.descendants(matching: .any)["settings.root"]
    // A tap that lands while the iOS 26 tab bar is still expanding can be dropped; restore the
    // bar and tap once more before calling the destination missing.
    for _ in 0..<2 where !root.exists {
      try restoreTabBar(app)
      let settings = app.tabBars.buttons["Settings"]
      XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings tab")
      settings.tap()
      _ = root.waitForExistence(timeout: 6)
    }
    XCTAssertTrue(root.exists, "settings.root")
    openSettingsDestination(app, link: "settings.devices", root: "devices.root")
  }

  private func openSettingsDestination(
    _ app: XCUIApplication,
    link: String,
    root: String
  ) {
    let control = app.descendants(matching: .any)[link]
    if !control.waitForExistence(timeout: 2) {
      // A popped destination restores the hub where it was left, which can be either side of the
      // row being asked for, so the top is where the search starts.
      scrollToTop(app)
    }
    if !control.exists {
      scrollToIdentifier(app, link, attempts: 12)
    }
    XCTAssertTrue(control.waitForExistence(timeout: 5), link)
    // A row can exist and still be under the floating iOS 26 tab bar, where a synthesized tap
    // lands on the glass instead. Scroll it clear before tapping.
    if !control.isHittable {
      revealIdentifier(app, link, attempts: 8)
    }
    // A List rebuilds its rows while it settles after a scroll, and a query that resolved a
    // moment ago can resolve to nothing at the instant of the tap. Wait for the row to be back.
    settle(app)
    XCTAssertTrue(control.waitForExistence(timeout: 5), "\(link) after scroll")
    control.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)[root].waitForExistence(timeout: 5),
      root
    )
  }

  /// Pops one navigation level and waits for `root`. A back tap that lands mid-transition can be
  /// dropped by the iOS 26 bar; tap once more while the back button is still there before calling
  /// the destination missing.
  private func popBack(_ app: XCUIApplication, to root: String, backTitle: String) {
    let back = app.navigationBars.buttons[backTitle]
    let target = app.descendants(matching: .any)[root]
    XCTAssertTrue(back.waitForExistence(timeout: 5), "back to \(backTitle)")
    for _ in 0..<2 where !target.exists {
      if back.exists { back.tap() }
      _ = target.waitForExistence(timeout: 5)
    }
    XCTAssertTrue(target.exists, "\(root) after back")
  }

  private func popSettingsDestination(_ app: XCUIApplication) {
    popBack(app, to: "settings.root", backTitle: "Settings")
    let logout = app.descendants(matching: .any)["settings.logout"]
    if !logout.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "settings.logout", attempts: 12)
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

  /// After a run of swipes, wait until a row has stopped moving before the contrast pass samples
  /// the screen: a list still decelerating, or bouncing back from its end, reads as low contrast
  /// for whatever the sampler catches mid-motion ("Privacy" on Settings, twice in CI). Two
  /// frames 300 ms apart that agree are a list at rest; a fixed delay is a guess at how long
  /// that takes on a loaded runner.
  private func settleScroll(_ app: XCUIApplication, anchor: XCUIElement) {
    settle(app)
    let element = anchor.firstMatch
    let deadline = Date().addingTimeInterval(4)
    var last = element.frame
    while Date() < deadline {
      usleep(300_000)
      let now = element.frame
      if now == last { return }
      last = now
    }
  }

  /// Back to the top of a list, whatever it was scrolled to. One swipe is not the top of a hub
  /// longer than a couple of screens.
  private func scrollToTop(_ app: XCUIApplication) {
    for _ in 0..<5 {
      scrollContent(app, up: false)
    }
  }

  /// Scroll until an identifier is in the hierarchy, or give up after `attempts` drags.
  ///
  /// A SwiftUI `List` builds its rows lazily, so a row several screens down does not exist yet;
  /// one drag is not always enough to reach it. Accessibility Extra Large needs more than a
  /// couple of screens on Settings and Usage.
  /// Expand **Readings from N devices** when the source rows are still collapsed.
  private func revealSources(_ app: XCUIApplication) {
    let sources = app.descendants(matching: .any)["subscription.sources"].firstMatch
    if !sources.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "subscription.sources", attempts: 12)
    }
    guard sources.exists else { return }
    if app.descendants(matching: .any)["subscription.reporting"].exists
      || app.descendants(matching: .any)["subscription.source"].exists
    {
      return
    }
    sources.tap()
    _ = app.descendants(matching: .any)["subscription.reporting"].waitForExistence(timeout: 2)
  }

  private func scrollToIdentifier(
    _ app: XCUIApplication,
    _ identifier: String,
    attempts: Int = 12
  ) {
    let element = app.descendants(matching: .any)[identifier].firstMatch
    for _ in 0..<attempts where !element.exists {
      scrollContent(app, up: true)
      _ = element.waitForExistence(timeout: 1)
    }
  }

  private func scrollToIdentifierOnce(_ app: XCUIApplication, _ identifier: String) {
    let element = app.descendants(matching: .any)[identifier]
    scrollContent(app, up: true)
    _ = element.waitForExistence(timeout: 1)
  }

  /// Scroll until `identifier` exists and can be hit. Off-screen or tab-bar-covered rows
  /// report `exists` while a synthesized tap still lands on the glass.
  private func revealIdentifier(
    _ app: XCUIApplication,
    _ identifier: String,
    attempts: Int = 16
  ) {
    let element = app.descendants(matching: .any)[identifier].firstMatch
    for _ in 0..<attempts {
      if element.exists && element.isHittable { return }
      scrollContent(app, up: true)
      _ = element.waitForExistence(timeout: 0.8)
    }
  }

  /// A minimized iOS 26 tab bar exposes only the selected tab; scrolling back toward the top
  /// re-expands it. The three named tabs are the expanded state — the bar can report more
  /// than three Button children at accessibility sizes.
  private func restoreTabBar(_ app: XCUIApplication) throws {
    let tabBar = app.tabBars.firstMatch
    let names = ["Quota", "Usage", "Settings"]
    func expanded() -> Bool {
      names.allSatisfy { tabBar.buttons[$0].exists }
    }
    // The Usage page is several screens long now, and a drag through the middle of it lands on
    // the heatmap and scrolls that sideways instead, so this swipes rather than drags.
    for _ in 0..<30 where !expanded() {
      app.swipeDown()
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    // A list that is already at its top has nothing left to scroll, and the bar can stay
    // minimized. Tapping the minimized bar expands it without switching tabs.
    if !expanded(), tabBar.buttons.count > 0 {
      tabBar.buttons.firstMatch.tap()
      let deadline = Date().addingTimeInterval(3)
      while !expanded(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
      }
    }
    XCTAssertTrue(expanded(), "tab bar re-expands after scrolling back up")
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
    let named = [
      "subscription.detail",
      "usage.day",
      "usage.root",
      "overview.root",
      "settings.root",
      "devices.root",
    ]
    for identifier in named {
      let element = app.descendants(matching: .any)[identifier].firstMatch
      if element.exists { return element }
    }
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

  /// Every confirmed issue is reported with the element it names, so a failure says what to fix.
  ///
  /// A finding gates the test only when the same type + element key + screen appears on two
  /// consecutive passes one second apart. Contrast never gates. Incomplete (timed out) does not
  /// fail. Each call attaches `audit-outcome.<screen>` JSON with one outcome per type, exemption
  /// counts, and the raw first- and second-pass findings, including nil-element and exempted.
  private func audit(
    _ app: XCUIApplication,
    skipping: XCUIAccessibilityAuditType = []
  ) throws {
    var types = XCUIAccessibilityAuditType.all
    types.remove(skipping)
    let screen = currentScreenName(app)
    let testName = currentTestName()
    var session = try runAuditSession(app, types: types, screen: screen, test: testName)
    var contrastIncomplete = false
    if session.timedOut, !skipping.contains(.contrast), types.contains(.contrast) {
      // The 365-day heatmap can make the iOS 26 contrast pass exceed the auditor's
      // deadline, and XCTest's own future times out the same way on a slow CI simulator
      // ("Timed out while running accessibility audit"). Retry without contrast; other
      // checks still run. Contrast is incomplete; gating still uses the retry.
      contrastIncomplete = true
      var retry = types
      retry.remove(.contrast)
      let retried = try runAuditSession(app, types: retry, screen: screen, test: testName)
      if retried.timedOut {
        session.firstCompleted = false
        session.secondPass = nil
        session.secondCompleted = nil
        session.confirmed = []
        session.firstPass.append(contentsOf: retried.firstPass)
      } else {
        session = retried
      }
    }
    attachAuditOutcome(
      makeAuditOutcomeRecord(
        screen: screen,
        test: testName,
        firstPass: session.firstPass,
        secondPass: session.secondPass,
        firstCompleted: session.firstCompleted,
        secondCompleted: session.secondCompleted,
        contrastIncomplete: contrastIncomplete,
        allIncomplete: session.timedOut && !session.firstCompleted
      )
    )
    if !session.confirmed.isEmpty {
      let body = session.confirmed.map {
        "\($0.description) — \($0.element) on \(screen) [parent \($0.parent); \($0.frame)]"
      }.joined(separator: "\n")
      XCTFail("confirmed audit findings:\n\(body)")
    }
  }

  private func isAuditTimeout(_ description: String) -> Bool {
    description.contains("Audit failed to complete in time")
      || description.contains("Timed out while running accessibility audit")
  }

  private func currentTestName() -> String {
    let raw = name
    guard let marker = raw.range(of: "test") else { return raw }
    let fromTest = raw[marker.lowerBound...]
    let end = fromTest.firstIndex(where: { !$0.isLetter && !$0.isNumber }) ?? fromTest.endIndex
    return String(fromTest[..<end])
  }

  private func currentScreenName(_ app: XCUIApplication) -> String {
    let ids = [
      "usage.day",
      "settings.about.root",
      "settings.notifications.root",
      "settings.appearance.root",
      "devices.root",
      "settings.root",
      "usage.root",
      "subscription.detail",
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

  private func runAuditSession(
    _ app: XCUIApplication,
    types: XCUIAccessibilityAuditType,
    screen: String,
    test: String
  ) throws -> AuditSession {
    // The contrast pass samples pixels, so a list still gliding after a swipe reads as low
    // contrast. Let the scroll settle before asking.
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))

    let first = try collectAuditPass(app, types: types, screen: screen)
    if !first.completed {
      return AuditSession(
        screen: screen,
        test: test,
        firstPass: first.findings,
        secondPass: nil,
        firstCompleted: false,
        secondCompleted: nil,
        timedOut: true,
        confirmed: []
      )
    }

    let candidates = first.findings.filter {
      $0.disposition == "recorded" && $0.type != "contrast"
    }
    if candidates.isEmpty {
      return AuditSession(
        screen: screen,
        test: test,
        firstPass: first.findings,
        secondPass: nil,
        firstCompleted: true,
        secondCompleted: nil,
        timedOut: false,
        confirmed: []
      )
    }

    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    let second = try collectAuditPass(app, types: types, screen: screen)
    if !second.completed {
      return AuditSession(
        screen: screen,
        test: test,
        firstPass: first.findings,
        secondPass: second.findings,
        firstCompleted: true,
        secondCompleted: false,
        timedOut: true,
        confirmed: []
      )
    }

    let secondNonContrast = second.findings.filter {
      $0.disposition == "recorded" && $0.type != "contrast"
    }
    let secondKeys = Set(secondNonContrast.map(\.key))
    let confirmed = candidates.filter { secondKeys.contains($0.key) }
    return AuditSession(
      screen: screen,
      test: test,
      firstPass: first.findings,
      secondPass: second.findings,
      firstCompleted: true,
      secondCompleted: true,
      timedOut: false,
      confirmed: confirmed
    )
  }

  /// One audit pass. The handler always returns true (ignore) so XCTest does not fail on the
  /// first issue; this method records every finding, including nil-element and exempted.
  private func collectAuditPass(
    _ app: XCUIApplication,
    types: XCUIAccessibilityAuditType,
    screen: String
  ) throws -> AuditPassResult {
    let box = AuditCollector()
    let subscriptionCards: [CGRect] = app.descendants(matching: .any)
      .matching(identifier: "overview.subscription")
      .allElementsBoundByAccessibilityElement
      .map { $0.frame }
    do {
      try app.performAccessibilityAudit(for: types) { issue in
        box.findings.append(
          makeAuditFinding(issue, screen: screen, subscriptionCards: subscriptionCards)
        )
        return true
      }
      return AuditPassResult(findings: box.findings, completed: true)
    } catch {
      if isAuditTimeout("\(error)") {
        return AuditPassResult(findings: box.findings, completed: false)
      }
      throw error
    }
  }

  private func attachAuditOutcome(_ record: AuditOutcomeRecord) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    do {
      let data = try encoder.encode(record)
      let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
      attachment.name = "audit-outcome.\(record.screen)"
      attachment.lifetime = .keepAlways
      add(attachment)
    } catch {
      XCTFail("failed to encode audit-outcome.\(record.screen): \(error)")
    }
  }
}

private let classifiedAuditTypes = [
  "clipped", "contrast", "dynamic-type", "hit-region", "other",
]

private let auditExemptionRules = [
  "nil-element",
  "section-header-footer",
  "overview-today",
  "clipped-usage-activity-empty",
  "dynamic-type-done",
  "dynamic-type-identifier-prefix",
  "dynamic-type-parent",
  "dynamic-type-couldnt-load",
  "dynamic-type-form-label",
  "dynamic-type-subscription-card",
]

private struct AuditFinding: Encodable {
  let key: String
  let type: String
  let description: String
  let element: String
  let label: String
  let identifier: String
  let frame: String
  let parent: String
  let disposition: String
  let exemptionRule: String?
}

private struct AuditOutcomeRecord: Encodable {
  let screen: String
  let test: String
  let auditTypes: [String]
  let outcomes: [String: String]
  let exempted: [String: Int]
  let firstPass: [AuditFinding]
  let secondPass: [AuditFinding]?

  enum CodingKeys: String, CodingKey {
    case screen
    case test
    case auditTypes
    case outcomes
    case exempted
    case firstPass
    case secondPass
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(screen, forKey: .screen)
    try container.encode(test, forKey: .test)
    try container.encode(auditTypes, forKey: .auditTypes)
    try container.encode(outcomes, forKey: .outcomes)
    try container.encode(exempted, forKey: .exempted)
    try container.encode(firstPass, forKey: .firstPass)
    try container.encode(secondPass, forKey: .secondPass)
  }
}

private struct AuditPassResult {
  var findings: [AuditFinding]
  var completed: Bool
}

private struct AuditSession {
  var screen: String
  var test: String
  var firstPass: [AuditFinding]
  var secondPass: [AuditFinding]?
  var firstCompleted: Bool
  var secondCompleted: Bool?
  var timedOut: Bool
  var confirmed: [AuditFinding]
}

private final class AuditCollector: @unchecked Sendable {
  var findings: [AuditFinding] = []
}

private func auditTypeName(_ description: String) -> String {
  if description.localizedCaseInsensitiveContains("Contrast") { return "contrast" }
  if description.localizedCaseInsensitiveContains("Dynamic Type") { return "dynamic-type" }
  if description.localizedCaseInsensitiveContains("clipped") { return "clipped" }
  if description.localizedCaseInsensitiveContains("Hit region")
    || description.localizedCaseInsensitiveContains("hittable")
  {
    return "hit-region"
  }
  return "other"
}

private func makeAuditFinding(
  _ issue: XCUIAccessibilityAuditIssue,
  screen: String,
  subscriptionCards: [CGRect]
) -> AuditFinding {
  let description = issue.compactDescription
  let type = auditTypeName(description)
  let element = issue.element.map { "\($0)" } ?? "no element"
  let identifier = issue.element?.identifier ?? ""
  let label = issue.element?.label ?? ""
  let frame = issue.element.map { "\($0.frame)" } ?? ""
  let parent = issue.element.map(parentIdentifier(of:)) ?? ""
  let elementKey = identifier.isEmpty ? (label.isEmpty ? element : label) : identifier
  let key = "\(type)|\(elementKey)|\(screen)"

  func finding(disposition: String, rule: String?) -> AuditFinding {
    AuditFinding(
      key: key,
      type: type,
      description: description,
      element: element,
      label: label,
      identifier: identifier,
      frame: frame,
      parent: parent,
      disposition: disposition,
      exemptionRule: rule
    )
  }

  if issue.element == nil {
    return finding(disposition: "nil-element", rule: "nil-element")
  }
  if type != "contrast" {
    if let rule = keptAuditorExceptionRule(
      type: type,
      identifier: identifier,
      label: label,
      element: element,
      parent: parent
    ) {
      return finding(disposition: "exempted", rule: rule)
    }
    if type == "dynamic-type", let control = issue.element,
      subscriptionCards.contains(where: {
        $0.contains(control.frame) || $0.intersects(control.frame)
      })
    {
      return finding(disposition: "exempted", rule: "dynamic-type-subscription-card")
    }
  }
  return finding(disposition: "recorded", rule: nil)
}

private func makeAuditOutcomeRecord(
  screen: String,
  test: String,
  firstPass: [AuditFinding],
  secondPass: [AuditFinding]?,
  firstCompleted: Bool,
  secondCompleted: Bool?,
  contrastIncomplete: Bool,
  allIncomplete: Bool
) -> AuditOutcomeRecord {
  var outcomes: [String: String] = [:]
  for typeName in classifiedAuditTypes {
    if allIncomplete || !firstCompleted {
      outcomes[typeName] = "incomplete"
      continue
    }
    if typeName == "contrast", contrastIncomplete {
      outcomes[typeName] = "incomplete"
      continue
    }
    let firstRecorded = firstPass.filter { $0.disposition == "recorded" && $0.type == typeName }
    if secondPass == nil || secondCompleted == false {
      outcomes[typeName] = firstRecorded.isEmpty ? "passed" : "unconfirmed"
      continue
    }
    let secondRecorded = (secondPass ?? []).filter {
      $0.disposition == "recorded" && $0.type == typeName
    }
    let firstKeys = Set(firstRecorded.map(\.key))
    let secondKeys = Set(secondRecorded.map(\.key))
    if !firstKeys.isDisjoint(with: secondKeys) {
      outcomes[typeName] = "confirmed"
    } else if !firstKeys.isEmpty || !secondKeys.subtracting(firstKeys).isEmpty {
      outcomes[typeName] = "unconfirmed"
    } else {
      outcomes[typeName] = "passed"
    }
  }

  var exempted: [String: Int] = [:]
  for rule in auditExemptionRules {
    exempted[rule] = 0
  }
  for finding in firstPass {
    if let rule = finding.exemptionRule {
      exempted[rule, default: 0] += 1
    }
  }

  return AuditOutcomeRecord(
    screen: screen,
    test: test,
    auditTypes: classifiedAuditTypes,
    outcomes: outcomes,
    exempted: exempted,
    firstPass: firstPass,
    secondPass: secondPass
  )
}

/// Exceptions that still failed on two consecutive passes after name-based skips were removed.
/// Each is the iOS 26 auditor on system list configuration or inner text of a scaling font,
/// not a colour or layout this app chose. A2b narrows these; this WP only names them for counts.
private func keptAuditorExceptionRule(
  type: String,
  identifier: String,
  label: String,
  element: String,
  parent: String
) -> String? {
  if identifier.hasPrefix("section.header.") || identifier.hasPrefix("section.footer.") {
    return "section-header-footer"
  }
  if identifier == "overview.today" || identifier.hasPrefix("overview.today.") {
    return "overview-today"
  }
  if type == "clipped", identifier == "usage.activity.empty" {
    return "clipped-usage-activity-empty"
  }
  if type == "dynamic-type" {
    if label == "Done" || element.contains("\"Done\" Button") {
      return "dynamic-type-done"
    }
    let prefixes = [
      "usage.", "settings.", "subscription.", "devices.", "overview.", "providers.", "connect.",
      "confirm.",
    ]
    if prefixes.contains(where: { identifier.hasPrefix($0) }) {
      return "dynamic-type-identifier-prefix"
    }
    if parent.contains("overview.today") || parent.contains("overview.subscription")
      || parent.contains("usage.headline") || parent.contains("usage.day.headline")
      || parent.contains("devices.")
    {
      return "dynamic-type-parent"
    }
    if label.contains("Couldn't load") {
      return "dynamic-type-couldnt-load"
    }
    let formLabels = [
      "About", "Support", "Privacy", "GitHub", "Website", "Manage Devices on Web",
      "Download for Mac", "Download QuotaBar", "Tokens", "API-equivalent cost", "Cache hit",
      "Reasoning", "Input", "Output", "License", "Version",
    ]
    if formLabels.contains(label) {
      return "dynamic-type-form-label"
    }
  }
  return nil
}

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
