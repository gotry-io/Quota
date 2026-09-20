import XCTest

/// The advisory screen census: one screen or state per test, reached with `--route` where the
/// fixture allows it, captured light/dark/large-type by the `ios-screens` workflow, and audited
/// with the accessibility auditor. CI runs this **outside** the merge queue: a finding here is a
/// defect to fix, not a reason a merge cannot proceed. The journeys that must keep working are
/// `QuotaSmokeUITests`.
final class QuotaScreenUITests: QuotaUITestCase {
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

  func testUsageEmptyShowsUnavailableCopyAndEmptyActivity() throws {
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
    let patterns = launch(fixture: "empty", route: "usage.patterns")
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

  /// Notifications, Appearance and About, each opened directly.
  func testSettingsNotificationsScreen() throws {
    try captureSettingsDestination(
      route: "settings.notifications",
      root: "settings.notifications.root",
      name: "settings-notifications"
    )
  }

  func testSettingsAppearanceScreen() throws {
    try captureSettingsDestination(
      route: "settings.appearance",
      root: "settings.appearance.root",
      name: "settings-appearance"
    )
  }

  func testSettingsAboutScreen() throws {
    try captureSettingsDestination(
      route: "settings.about",
      root: "settings.about.root",
      name: "settings-about"
    )
  }

  /// Every provider connection state on one screen: two Codex accounts, a refused session, a
  /// connected Claude Code, and the rows that add another.
  func testProvidersMatrixScreen() throws {
    let app = launch(fixture: "providers", route: "settings")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    scrollToIdentifier(app, "providers.session.codex:codex_work", attempts: 12)
    XCTAssertTrue(
      app.descendants(matching: .any)["providers.session.codex:codex_work"]
        .waitForExistence(timeout: 5),
      "first connected Codex account"
    )
    settle(app)
    attachScreenshot(app, name: "settings-providers")
    try audit(app)
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

  /// Devices reached directly, so the journey does not have to carry its picture.
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

  /// What this phone read for itself, in detail: its own remaining history and sources.
  func testLocalOnlySubscriptionDetailScreen() throws {
    let app = launch(fixture: "local-only")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    app.descendants(matching: .any)["overview.subscription"].firstMatch.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.detail"].waitForExistence(timeout: 5),
      "subscription.detail"
    )
    let history = app.descendants(matching: .any)["subscription.history"].firstMatch
    if !history.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "subscription.history", attempts: 12)
    }
    XCTAssertTrue(history.waitForExistence(timeout: 5), "subscription.history")
    attachScreenshot(app, name: "subscription-detail-local")
    settle(app)
    try audit(app)

    // What read it is the other half of a local-only detail: the disclosure lists the sources, and
    // this phone is one of them.
    revealSources(app)
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.sources"].exists,
      "subscription.sources"
    )
    scrollToIdentifier(app, "subscription.reporting")
    XCTAssertTrue(app.staticTexts["This iPhone"].waitForExistence(timeout: 5), "This iPhone")
  }

  func testLocalOnlySettingsScreen() throws {
    let app = launch(fixture: "local-only", route: "settings")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    XCTAssertFalse(
      app.descendants(matching: .any)["settings.devices"].exists,
      "Devices row is absent when signed out"
    )
    settle(app)
    attachScreenshot(app, name: "settings-local-only")
    try audit(app)
  }

  private func captureSettingsDestination(route: String, root: String, name: String) throws {
    let app = launch(fixture: "content", route: route)
    XCTAssertTrue(app.descendants(matching: .any)[root].waitForExistence(timeout: 10), root)
    settle(app)
    attachScreenshot(app, name: name)
    try audit(app)
  }

  private func captureRoot(fixture: String, root: String, name: String) throws {
    let app = launch(fixture: fixture)
    XCTAssertTrue(app.descendants(matching: .any)[root].waitForExistence(timeout: 10), root)
    settle(app)
    attachScreenshot(app, name: name)
    try audit(app)
  }
}
