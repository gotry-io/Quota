import XCTest

/// The advisory screen census: one screen or state per test, launched straight onto it with
/// `--route` (or a fixture whose first screen it is), captured light/dark/large-type by the
/// `ios-screens` workflow, and audited with the accessibility auditor. No test here taps through
/// one screen to reach another, so a finding on one screen never hides the evidence of the next.
/// CI runs this **outside** the merge queue: a finding here is a defect to fix, not a reason a
/// merge cannot proceed. The journeys that must keep working are `QuotaSmokeUITests`.
final class QuotaScreenUITests: QuotaUITestCase {
  func testNoDevicesOverviewShowsMacSetup() throws {
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
    // At accessibility sizes the Mac-setup group starts below the fold, and a lazy List has not
    // built it yet: the same reveal its neighbours get, or this asserts what is merely on screen.
    if !app.staticTexts["Set up QuotaBar"].exists {
      scrollToIdentifier(app, "section.header.mac-setup", attempts: 12)
    }
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
  }

  func testNoDevicesDevicesScreen() throws {
    let devices = launch(fixture: "no-devices", route: "settings.devices")
    XCTAssertTrue(
      devices.descendants(matching: .any)["devices.root"].waitForExistence(timeout: 10),
      "devices.root"
    )
    XCTAssertTrue(
      devices.staticTexts["No Macs connected"].waitForExistence(timeout: 5),
      "No Macs connected"
    )
    XCTAssertTrue(
      devices.descendants(matching: .any)["Download QuotaBar"].waitForExistence(timeout: 5),
      "Download QuotaBar"
    )
    XCTAssertTrue(
      devices.descendants(matching: .any)["Manage Devices on Web"].exists,
      "Manage Devices on Web"
    )
    settle(devices)
    attachScreenshot(devices, name: "devices-empty")
    try audit(devices)
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
    let app = launch(fixture: "content", route: "settings.devices")
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

  /// One subscription two Macs and this phone all read stays one row.
  func testMergedOverviewScreen() throws {
    let app = launch(fixture: "merged")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    settle(app)
    attachScreenshot(app, name: "overview-merged")
    try audit(app)
  }

  /// That row's detail, opened directly: its history, and every source that read it.
  func testMergedSubscriptionDetailScreen() throws {
    let app = launch(fixture: "merged", route: "subscription.detail/codex|visual_codex|global|")
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.detail"].waitForExistence(timeout: 10),
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
    settle(app, anchor: mergedHistory)
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
    settle(app, anchor: github)
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

  /// Nothing read yet and the first refresh on its way: the tabs, with one placeholder card per
  /// provider session rather than the empty state.
  func testLoadingFixtureShowsPlaceholderCards() throws {
    let app = launch(fixture: "loading")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "overview.placeholder").count, 2)
    XCTAssertFalse(app.descendants(matching: .any)["overview.empty"].exists, "no empty state")
    XCTAssertFalse(app.buttons["overview.refresh"].isEnabled, "refresh button waits")
    attachScreenshot(app, name: "overview-loading")
    try audit(app)
  }

  /// A refresh in flight over what is already on screen: **Updating…** under the title, the
  /// refresh button busy, and the one row still waiting for its reading marked in place.
  func testUpdatingFixtureShowsProgressInTheTitleAndThePendingRow() throws {
    let app = launch(fixture: "updating")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    XCTAssertTrue(app.staticTexts["Updating… 2 of 3"].waitForExistence(timeout: 5), "subtitle")
    XCTAssertFalse(app.buttons["overview.refresh"].isEnabled, "refresh button waits")
    attachScreenshot(app, name: "overview-updating")
    try audit(app)
  }

  /// Idle: the age under the title and a refresh button that can be pressed.
  func testContentFixtureShowsTheAgeUnderTheTitle() throws {
    let app = launch(fixture: "content")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    let age = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Updated '"))
    XCTAssertTrue(age.firstMatch.waitForExistence(timeout: 5), "subtitle")
    XCTAssertTrue(app.buttons["Refresh"].isEnabled, "Refresh")
    attachScreenshot(app, name: "overview-idle")
  }

  /// The launch mark held still at the start of its fill (the faint track alone), halfway, and
  /// filled, over the Overview it fades into.
  func testLaunchFixtureShowsTheMark() throws {
    for (progress, name) in [("0", "launch-mark-start"), ("0.5", "launch-mark-mid"), ("1", "launch-mark-end")] {
      let app = launch(fixture: "launch", extra: ["--launch-progress", progress])
      XCTAssertTrue(
        app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
        "overview.root"
      )
      attachScreenshot(app, name: name)
      app.terminate()
    }
  }

  func testUsageEmptyScreen() throws {
    let app = launch(fixture: "empty", route: "usage")
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
    attachScreenshot(app, name: "usage-empty")
    try audit(app)
  }

  func testUsagePatternsEmptyScreen() throws {
    let patterns = launch(fixture: "empty", route: "usage.patterns")
    XCTAssertTrue(
      patterns.descendants(matching: .any)["usage.patterns"].waitForExistence(timeout: 10),
      "usage.patterns"
    )
    let emptyActivity = patterns.staticTexts["No activity in the last year."]
    if !emptyActivity.waitForExistence(timeout: 2) {
      scrollToIdentifierOnce(patterns, "usage.activity.empty")
    }
    XCTAssertTrue(
      emptyActivity.waitForExistence(timeout: 5)
        || patterns.descendants(matching: .any)["usage.activity.empty"].exists,
      "empty activity"
    )
    settle(patterns)
    attachScreenshot(patterns, name: "usage-patterns-empty")
    try audit(patterns)
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
    let app = launch(fixture: "activity-loading", route: "usage.patterns")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.patterns"].waitForExistence(timeout: 10)
        || app.navigationBars["Activity patterns"].waitForExistence(timeout: 10),
      "usage.patterns"
    )
    if !app.descendants(matching: .any)["usage.activity.loading"].waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "usage.activity.loading")
    }
    XCTAssertTrue(
      app.descendants(matching: .any)["Loading activity"].waitForExistence(timeout: 5)
        || app.descendants(matching: .any)["usage.activity.loading"].exists,
      "usage.activity.loading"
    )
    attachScreenshot(app, name: "usage-activity-loading")
    try audit(app)
  }

  func testUsageActivityFailedShowsRetry() throws {
    let app = launch(fixture: "activity-failed", route: "usage.patterns")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.patterns"].waitForExistence(timeout: 10)
        || app.navigationBars["Activity patterns"].waitForExistence(timeout: 10),
      "usage.patterns"
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

  /// Overview with an Account: the layout, the Today row, and the whole-screen audit that the
  /// journey no longer carries.
  func testOverviewContentScreen() throws {
    let app = launch(fixture: "content")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    revealIdentifier(app, "overview.today")
    XCTAssertFalse(
      app.descendants(matching: .any)["overview.today.input"].exists,
      "Input tile is gone"
    )
    XCTAssertFalse(
      app.descendants(matching: .any)["overview.today.output"].exists,
      "Output tile is gone"
    )
    XCTAssertFalse(
      app.staticTexts["Studio Mac"].exists,
      "Devices summary does not duplicate onto Overview"
    )
    settle(app)
    attachScreenshot(app, name: "overview-content")
    try audit(app)
    try assertListScrolls(app, screenshot: "overview-scrolled")
  }

  /// A subscription this phone has no readings for: identity, windows, why there is no history,
  /// and the devices that did report.
  func testSubscriptionDetailRemoteOnlyScreen() throws {
    let app = launch(fixture: "content", route: "subscription.detail/codex|visual_codex|global|")
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.detail"].waitForExistence(timeout: 10),
      "subscription.detail"
    )
    let account = app.descendants(matching: .any)["subscription.account"]
    if !account.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "subscription.account", attempts: 8)
    }
    XCTAssertTrue(account.waitForExistence(timeout: 5), "Account")
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
    let reporting = app.descendants(matching: .any)["subscription.reporting"]
    if !reporting.waitForExistence(timeout: 2) {
      revealSources(app)
      scrollToIdentifier(app, "subscription.reporting", attempts: 12)
    }
    XCTAssertTrue(reporting.waitForExistence(timeout: 5), "Reporting")
    attachScreenshot(app, name: "subscription-detail")
    try audit(app)
  }

  /// The Settings hub itself.
  func testSettingsHubScreen() throws {
    let app = launch(fixture: "content", route: "settings")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.devices"].waitForExistence(timeout: 5),
      "Devices row"
    )
    settle(app)
    attachScreenshot(app, name: "settings-main")
    try audit(app)
  }

  /// Notifications, Appearance and About, each opened directly: the picture and audit first, at
  /// the top of the destination, then what it says and offers.
  func testSettingsNotificationsScreen() throws {
    let app = try captureSettingsDestination(
      route: "settings.notifications",
      root: "settings.notifications.root",
      name: "settings-notifications"
    )
    // Its switches are the journey's (`QuotaSmokeUITests.testSettingsDestinationsOpenAndReturn`).
    // Below the fold at accessibility sizes.
    let alertAt = app.staticTexts["Alert at"].firstMatch
    for _ in 0..<8 where !alertAt.exists {
      scrollContent(app, up: true)
      _ = alertAt.waitForExistence(timeout: 1)
    }
    XCTAssertTrue(alertAt.exists, "Alert at")
  }

  /// Its three options are the journey's (`QuotaSmokeUITests.testSettingsDestinationsOpenAndReturn`).
  func testSettingsAppearanceScreen() throws {
    try captureSettingsDestination(
      route: "settings.appearance",
      root: "settings.appearance.root",
      name: "settings-appearance"
    )
  }

  /// About's words and links, all of them: the product and privacy sentences, the version, and
  /// the three links.
  func testSettingsAboutScreen() throws {
    let app = try captureSettingsDestination(
      route: "settings.about",
      root: "settings.about.root",
      name: "settings-about"
    )
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
      app.staticTexts[
        "This iPhone never uploads its sign-ins. Only the readings it takes reach your Account."
      ].exists,
      "privacy sentence"
    )
    if !app.descendants(matching: .any)["settings.about.version"].waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "settings.about.version", attempts: 8)
    }
    XCTAssertTrue(
      app.staticTexts["Version"].exists
        || app.descendants(matching: .any)["settings.about.version"].exists,
      "Version"
    )
    for link in ["Website", "GitHub"] {
      if !app.descendants(matching: .any)[link].waitForExistence(timeout: 2) {
        scrollToIdentifier(app, link, attempts: 6)
      }
      XCTAssertTrue(app.descendants(matching: .any)[link].exists, link)
    }
    if !app.descendants(matching: .any)["settings.about.license"].waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "settings.about.license", attempts: 6)
    }
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.about.license"].exists
        || app.staticTexts["License"].exists,
      "License MIT"
    )
  }

  /// Every provider connection state on one screen: two Codex accounts, a refused session, a
  /// connected Claude Code, and the rows that add another. The picture and audit are taken at the
  /// first connected row; then every row is walked, at whatever size the profile runs.
  func testProvidersMatrixScreen() throws {
    let app = launch(fixture: "providers", route: "settings")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    let first = app.descendants(matching: .any)["providers.session.codex:codex_work"].firstMatch
    scrollToIdentifier(app, "providers.session.codex:codex_work", attempts: 12)
    XCTAssertTrue(first.waitForExistence(timeout: 5), "first connected Codex account")
    settle(app, anchor: first)
    attachScreenshot(app, name: "settings-providers")
    try audit(app)

    // The header can be on screen while a connected row is still below the fold and not yet built
    // by the lazy List, so each row is scrolled to rather than merely asserted.
    for identifier in [
      "providers.session.codex:codex_work",
      "providers.remove.codex:codex_work",
      "providers.session.claude:claude_team",
    ] {
      // The lazy List may have dropped a row above the one the audit left on screen, so a row
      // that is not built yet is searched for from the top.
      if !app.descendants(matching: .any)[identifier].waitForExistence(timeout: 2) {
        scrollToTop(app)
        scrollToIdentifier(app, identifier, attempts: 12)
      }
      XCTAssertTrue(
        app.descendants(matching: .any)[identifier].waitForExistence(timeout: 5),
        identifier
      )
    }
    // The refused session's Sign in again is the journey's
    // (`QuotaSmokeUITests.testRefusedProviderSessionOffersSignInAgain`).
    // A provider with nothing connected offers Connect; one that already has an account offers
    // another.
    let grokConnect = app.descendants(matching: .any)["providers.connect.grok"]
    if !grokConnect.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "providers.connect.grok", attempts: 12)
    }
    XCTAssertTrue(grokConnect.waitForExistence(timeout: 5), "Grok Connect row")
    XCTAssertTrue(
      grokConnect.label.contains("Connect"),
      "a provider with nothing connected offers Connect, got \(grokConnect.label)"
    )
    let codexConnect = app.descendants(matching: .any)["providers.connect.codex"]
    if !codexConnect.waitForExistence(timeout: 2) {
      scrollToTop(app)
      scrollToIdentifier(app, "providers.connect.codex", attempts: 12)
    }
    XCTAssertTrue(codexConnect.waitForExistence(timeout: 5), "Codex Add Account row")
    XCTAssertTrue(
      codexConnect.label.contains("Add Account"),
      "a provider already connected offers another account, got \(codexConnect.label)"
    )
  }

  /// Usage with an Account: the period chooser, the two headline values and the daily chart.
  func testUsageContentScreen() throws {
    let app = launch(fixture: "content", route: "usage")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 10),
      "usage.root"
    )
    selectLast30DaysIfNeeded(app)
    settle(app)
    attachScreenshot(app, name: "usage-content")
    try audit(app)
  }

  /// Usage on Today, opened directly on that period: the capture the period journey used to take.
  func testUsageTodayScreen() throws {
    let app = launch(fixture: "content", route: "usage.today")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 10),
      "usage.root"
    )
    let period = app.descendants(matching: .any)["usage.period"].firstMatch
    XCTAssertTrue(period.waitForExistence(timeout: 5), "usage period menu")
    XCTAssertTrue(
      selectedPeriod(app).contains("Today"), "opened on Today, got \(selectedPeriod(app))")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.headline"].waitForExistence(timeout: 5),
      "usage.headline"
    )
    settle(app)
    attachScreenshot(app, name: "usage-today")
    try audit(app)
  }

  /// Usage on a fixed custom range (`--route usage.custom`: August 8 – 12, 2026, the range the
  /// period journey picks by hand).
  func testUsageCustomRangeScreen() throws {
    let app = launch(fixture: "content", route: "usage.custom")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 10),
      "usage.root"
    )
    let period = app.descendants(matching: .any)["usage.period"].firstMatch
    XCTAssertTrue(period.waitForExistence(timeout: 5), "usage period menu")
    XCTAssertTrue(
      selectedPeriod(app).contains("Custom"),
      "opened on the custom range, got \(selectedPeriod(app))"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.headline"].waitForExistence(timeout: 5),
      "usage.headline"
    )
    let title = app.descendants(matching: .any)["usage.period.title"].firstMatch
    XCTAssertTrue(
      title.label.hasPrefix("Aug 8 – Aug 12, 2026"), "the custom range's title, got \(title.label)")
    settle(app)
    attachScreenshot(app, name: "usage-custom")
    try audit(app)
  }

  /// By provider / By model, and Activity patterns, each opened directly.
  func testUsageBreakdownScreen() throws {
    let app = launch(fixture: "content", route: "usage.breakdown")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.breakdown"].waitForExistence(timeout: 10),
      "usage.breakdown"
    )
    settle(app)
    attachScreenshot(app, name: "usage-breakdown")
    try audit(app)
  }

  func testUsagePatternsScreen() throws {
    let app = launch(fixture: "content", route: "usage.patterns")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.patterns"].waitForExistence(timeout: 10),
      "usage.patterns"
    )
    settle(app)
    attachScreenshot(app, name: "usage-patterns")
    try audit(app)
  }

  /// The day sheet with content, which the journey opens and this census pictures.
  func testUsageDayScreen() throws {
    let app = launch(fixture: "content", route: "usage.day")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.day"].waitForExistence(timeout: 10),
      "usage.day"
    )
    settle(app)
    attachScreenshot(app, name: "usage-day")
    try audit(app)
  }

  /// The account states the smoke tests assert controls for: their copy and their audit.
  func testSignedOutScreen() throws {
    try captureRoot(fixture: "signed-out", root: "overview.root", name: "overview-signed-out")
  }

  func testSignInSheetScreen() throws {
    try captureRoot(fixture: "sign-in", root: "connect.root", name: "connect-sign-in")
  }

  func testConfirmAccountScreen() throws {
    try captureRoot(fixture: "confirm-account", root: "confirm.root", name: "confirm-account")
  }

  func testConnectRefreshFailedScreen() throws {
    try captureRoot(
      fixture: "connect-refresh-failed",
      root: "connect.root",
      name: "connect-refresh-failed"
    )
  }

  func testConnectingScreen() throws {
    try captureRoot(fixture: "connecting", root: "connect.root", name: "connect-connecting")
  }

  /// A phone with only its own providers: the Overview it does have, and its Settings hub.
  func testLocalOnlyOverviewScreen() throws {
    try captureRoot(fixture: "local-only", root: "overview.root", name: "overview-local-only")
  }

  /// What this phone read for itself, in detail, opened directly: its own remaining history with
  /// this iPhone named beside it, and the sources disclosure with this iPhone reporting.
  func testLocalOnlySubscriptionDetailScreen() throws {
    let app = launch(
      fixture: "local-only", route: "subscription.detail/codex|visual_codex_phone|global|")
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.detail"].waitForExistence(timeout: 10),
      "subscription.detail"
    )
    let history = app.descendants(matching: .any)["subscription.history"].firstMatch
    if !history.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "subscription.history", attempts: 12)
    }
    XCTAssertTrue(history.waitForExistence(timeout: 5), "subscription.history")
    // What this phone read for itself has samples behind it, so remaining history plots them.
    XCTAssertTrue(
      app.staticTexts["Remaining history"].waitForExistence(timeout: 5),
      "history title"
    )
    XCTAssertTrue(app.staticTexts["This iPhone"].exists, "This iPhone beside remaining history")
    settle(app, anchor: history)
    attachScreenshot(app, name: "subscription-detail-local")
    try audit(app)

    // What read it is the other half of a local-only detail: the disclosure lists the sources, and
    // this phone is one of them.
    revealSources(app)
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.sources"].exists,
      "subscription.sources"
    )
    scrollToIdentifier(app, "subscription.reporting")
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.reporting"].waitForExistence(timeout: 5),
      "subscription.reporting"
    )
    XCTAssertTrue(app.staticTexts["This iPhone"].waitForExistence(timeout: 5), "This iPhone")
  }

  func testLocalOnlySettingsScreen() throws {
    let app = launch(fixture: "local-only", route: "settings")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    settle(app)
    attachScreenshot(app, name: "settings-local-only")
    try audit(app)
  }

  @discardableResult
  private func captureSettingsDestination(route: String, root: String, name: String) throws
    -> XCUIApplication
  {
    let app = launch(fixture: "content", route: route)
    XCTAssertTrue(app.descendants(matching: .any)[root].waitForExistence(timeout: 10), root)
    settle(app)
    attachScreenshot(app, name: name)
    try audit(app)
    return app
  }

  private func captureRoot(fixture: String, root: String, name: String) throws {
    let app = launch(fixture: fixture)
    XCTAssertTrue(app.descendants(matching: .any)[root].waitForExistence(timeout: 10), root)
    settle(app)
    attachScreenshot(app, name: name)
    try audit(app)
  }
}
