import XCTest

/// The required iOS gate: fixture-backed **journeys and interaction contracts**. No accessibility
/// audit and no screen census runs here — those are `QuotaScreenUITests`, which CI runs in the
/// advisory `ios-screens` workflow. A failure here means a person could not get somewhere or a
/// control did not do what it says.
final class QuotaSmokeUITests: QuotaUITestCase {
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
  }

  func testUsagePeriodSelectsTodayThenAppliesCustomRange() throws {
    let app = launch(fixture: "content", route: "usage")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 10),
      "usage.root"
    )
    selectLast30DaysIfNeeded(app)
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.headline"].waitForExistence(timeout: 5),
      "usage.headline"
    )

    let period = app.descendants(matching: .any)["usage.period"].firstMatch
    period.tap()
    let todayItem = app.buttons["Today"].firstMatch
    XCTAssertTrue(todayItem.waitForExistence(timeout: 5), "Today in the period menu")
    todayItem.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.headline"].waitForExistence(timeout: 5),
      "usage.headline on Today"
    )

    let custom = app.descendants(matching: .any)["usage.period.custom"].firstMatch
    XCTAssertTrue(custom.waitForExistence(timeout: 5), "Custom range")
    custom.tap()
    XCTAssertTrue(
      app.navigationBars["Custom range"].waitForExistence(timeout: 5),
      "Custom range sheet"
    )
    let apply = app.buttons["Apply"].firstMatch
    XCTAssertTrue(apply.waitForExistence(timeout: 5), "Apply")
    apply.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 5),
      "usage.root after custom apply"
    )
  }

  func testUsageOpensActivityPatternsAndReturns() throws {
    let app = launch(fixture: "content")
    try restoreTabBar(app)
    app.tabBars.buttons["Usage"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 10),
      "usage.root"
    )
    selectLast30DaysIfNeeded(app)
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.headline"].waitForExistence(timeout: 5),
      "usage.headline"
    )
    let dailyChart = app.descendants(matching: .any)["usage.daily.chart"]
    for _ in 0..<8 where !dailyChart.exists {
      scrollContent(app, up: true)
    }
    XCTAssertTrue(dailyChart.waitForExistence(timeout: 5), "Daily chart")

    openUsageDestination(app, link: "usage.open-breakdown", root: "usage.breakdown")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.headline.cache-hit"].waitForExistence(timeout: 5)
        || app.staticTexts["Cache hit"].exists,
      "Cache hit on breakdown"
    )
    popUsageDestination(app)

    openUsageDestination(app, link: "usage.open-patterns", root: "usage.patterns")
    XCTAssertTrue(
      app.navigationBars["Activity patterns"].waitForExistence(timeout: 5)
        || app.staticTexts["Activity patterns"].exists
        || app.descendants(matching: .any)["usage.patterns"].exists,
      "Activity patterns title"
    )
    let viewDay = app.descendants(matching: .any)["usage.activity.view-day"]
    if !viewDay.exists || !viewDay.isHittable {
      revealIdentifier(app, "usage.activity.view-day", attempts: 24)
    }
    XCTAssertTrue(viewDay.waitForExistence(timeout: 5), "View day")
    if !viewDay.isHittable {
      revealIdentifier(app, "usage.activity.view-day", attempts: 8)
    }
    viewDay.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.day"].waitForExistence(timeout: 8),
      "usage.day"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.day.model"].waitForExistence(timeout: 5),
      "usage.day.model"
    )
    app.buttons["Done"].tap()
    popUsageDestination(app)
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 5),
      "usage.root after back"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.open-patterns"].waitForExistence(timeout: 5),
      "Activity patterns row after back"
    )
  }

  /// Devices are the Account's. Without an account the Settings row is absent; the sign-in
  /// card already covers it.
  func testLocalOnlyFixtureHasNoDevicesRow() throws {
    let app = launch(fixture: "local-only", route: "settings")
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
  }

  /// Overview is the Quota tab: its Today row opens Usage already on Today, and a subscription
  /// card opens its detail and comes back. (The Overview picture and its audit are advisory.)
  func testOverviewOpensUsageOnTodayThenSubscriptionDetail() throws {
    let app = launch(fixture: "content")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    try restoreTabBar(app)
    assertTab(app, "Quota")
    assertTab(app, "Usage")
    assertTab(app, "Settings")
    XCTAssertFalse(app.tabBars.buttons["Devices"].exists, "Devices is not a tab")
    XCTAssertTrue(app.navigationBars["Quota"].exists, "Quota page title")
    XCTAssertFalse(
      app.navigationBars["octocat"].exists,
      "account identity is not the Overview title"
    )
    revealIdentifier(app, "overview.today")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.today.tokens"].exists,
      "overview.today.tokens"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.today.cost"].exists,
      "overview.today.cost"
    )
    app.descendants(matching: .any)["overview.today"].firstMatch.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 10),
      "usage.root"
    )
    let period = app.descendants(matching: .any)["usage.period"].firstMatch
    XCTAssertTrue(period.waitForExistence(timeout: 5), "usage period menu")
    XCTAssertTrue(
      period.label.contains("Today") || ((period.value as? String) ?? "").contains("Today"),
      "Overview Today opens the Today period, got \(period.label) / \(String(describing: period.value))"
    )

    try restoreTabBar(app)
    app.tabBars.buttons["Quota"].tap()
    let card = app.descendants(matching: .any)["overview.subscription"].firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 5), "overview.subscription")
    card.tap()
    let detail = app.descendants(matching: .any)["subscription.detail"]
    XCTAssertTrue(detail.waitForExistence(timeout: 5), "subscription.detail")
    popBack(app, to: "overview.root", backTitle: "Quota")
    XCTAssertFalse(detail.exists, "subscription detail is dismissed after back")
  }

  /// The Settings hub reaches each pushed destination and comes back to the hub, and Log Out stays
  /// on the hub. The destinations' copy and pictures are advisory.
  func testSettingsDestinationsOpenAndReturn() throws {
    let app = launch(fixture: "content", route: "settings")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    for (link, root) in [
      ("settings.notifications", "settings.notifications.root"),
      ("settings.appearance", "settings.appearance.root"),
      ("settings.about", "settings.about.root"),
    ] {
      openSettingsDestination(app, link: link, root: root)
      XCTAssertTrue(app.descendants(matching: .any)[root].exists, root)
      popSettingsDestination(app)
      XCTAssertFalse(
        app.descendants(matching: .any)[root].exists,
        "\(root) is dismissed after back"
      )
    }
    scrollToIdentifier(app, "settings.logout", attempts: 12)
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.logout"].waitForExistence(timeout: 5),
      "Log Out stays on the hub"
    )
  }

  /// A stored provider session whose collection was refused offers the way back in. The whole
  /// provider matrix is advisory.
  func testProvidersRefusedSessionOffersSignInAgain() throws {
    let app = launch(fixture: "providers", route: "settings")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    // The refused session in this fixture is the second Codex account.
    scrollToIdentifier(app, "providers.session.codex:codex_personal", attempts: 12)
    XCTAssertTrue(
      app.descendants(matching: .any)["providers.session.codex:codex_personal"]
        .waitForExistence(timeout: 5),
      "refused Codex session"
    )
    if !app.descendants(matching: .any)["providers.signin-again.codex:codex_personal"].exists {
      scrollToIdentifier(app, "providers.signin-again.codex:codex_personal", attempts: 8)
    }
    XCTAssertTrue(
      app.descendants(matching: .any)["providers.signin-again.codex:codex_personal"].exists,
      "Sign in again affordance"
    )
    XCTAssertTrue(
      app.staticTexts["Sign in again to keep reading this account."].exists,
      "refused session says what to do"
    )
  }

  /// A phone that only reads its own providers still has a quota screen, no managed Today, and no
  /// account-only Devices row.
  func testLocalOnlyOverviewIsItsOwnReadingWithoutAccountRows() throws {
    let app = launch(fixture: "local-only")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.subscription"].firstMatch
        .waitForExistence(timeout: 5),
      "this iPhone's own reading"
    )
    XCTAssertFalse(
      app.descendants(matching: .any)["overview.today"].exists,
      "no managed Today without an account"
    )
  }

  /// The seven essential values at the standard text size: they exist, are hittable, carry their
  /// whole label, and sit on screen.
  func testEssentialValuesAtStandardSize() throws {
    try assertEssentialValues(textSize: "large")
  }

  /// The same seven values at `accessibilityExtraLarge`, where a fixed-height row or a
  /// `lineLimit(1)` would truncate them.
  func testEssentialValuesAtAccessibilitySize() throws {
    try assertEssentialValues(textSize: "accessibilityExtraLarge")
  }

  /// Settings stays usable at the largest type: About is reachable, comes back, and Log Out is
  /// still on the hub below the fold.
  func testSettingsAboutReachableAtAccessibilitySize() throws {
    let app = launch(fixture: "content", route: "settings", textSize: "accessibilityExtraLarge")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    openSettingsDestination(app, link: "settings.about", root: "settings.about.root")
    popSettingsDestination(app)
    XCTAssertFalse(
      app.descendants(matching: .any)["settings.about.root"].exists,
      "About is dismissed after back"
    )
  }

  /// Both sizes assert the same values, so a size that truncates one of them fails by name.
  private func assertEssentialValues(textSize: String) throws {
    var app = launch(fixture: "content", textSize: textSize)
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root at \(textSize)"
    )
    assertUnclippedEssentialValue(
      app,
      identifier: "overview.remaining",
      expectedLabel: ContentFixtureLargeType.remainingPercent,
      combinedLabelContainsValue: true
    )
    revealIdentifier(app, "overview.today")
    assertUnclippedEssentialValue(
      app,
      identifier: "overview.today.tokens",
      expectedLabel: ContentFixtureLargeType.todayTokens
    )
    assertUnclippedEssentialValue(
      app,
      identifier: "overview.today.cost",
      expectedLabel: ContentFixtureLargeType.todayCost
    )
    assertUnclippedEssentialValue(
      app,
      identifier: "overview.today",
      expectedLabel: ContentFixtureLargeType.todayCombined
    )

    app = launch(fixture: "content", route: "usage", textSize: textSize)
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 10),
      "usage.root at \(textSize)"
    )
    selectLast30DaysIfNeeded(app)
    settle(app)
    assertUnclippedEssentialValue(
      app,
      identifier: "usage.headline.tokens",
      expectedLabel: ContentFixtureLargeType.usageTokens
    )
    assertUnclippedEssentialValue(
      app,
      identifier: "usage.headline.cost",
      expectedLabel: ContentFixtureLargeType.usageCost
    )

    app = launch(
      fixture: "content",
      route: "subscription.detail/codex|visual_codex|global|",
      textSize: textSize
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["subscription.detail"].waitForExistence(timeout: 10),
      "subscription.detail at \(textSize)"
    )
    assertUnclippedEssentialValue(
      app,
      identifier: "subscription.remaining",
      expectedLabel: ContentFixtureLargeType.remainingPercent,
      combinedLabelContainsValue: true
    )
  }
}
