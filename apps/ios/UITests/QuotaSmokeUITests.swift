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
    popBack(app, from: "devices.root", to: "settings.root", backTitle: "Settings")
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

  /// The invitation opens the one page that offers every way in, over the tabs it was asked from,
  /// and dismissing that page returns to the Overview it was opened from, invitations intact.
  func testSignInInvitationOpensEveryWayInAndDismisses() throws {
    let app = launch(fixture: "signed-out")
    let overview = app.descendants(matching: .any)["overview.root"]
    XCTAssertTrue(overview.waitForExistence(timeout: 10), "overview.root")
    let invitation = app.buttons["Sign in to Quota"].firstMatch
    XCTAssertTrue(invitation.waitForExistence(timeout: 5), "Sign in to Quota")
    tapToOpen(invitation, in: app, "Sign in to Quota", destination: "connect.root")

    let sheet = app.descendants(matching: .any)["connect.root"].firstMatch
    XCTAssertTrue(app.descendants(matching: .any)["connect.apple"].exists, "Continue with Apple")
    XCTAssertTrue(app.buttons["Continue with GitHub"].exists, "Continue with GitHub")
    XCTAssertTrue(app.buttons["Continue with Email"].exists, "Continue with Email")
    XCTAssertFalse(
      app.descendants(matching: .any)["connect.connecting"].exists,
      "nothing is in flight until a way in is chosen"
    )

    // The sheet has no close button: it is dismissed the way a person does, by pulling it down.
    settle(app, anchor: sheet)
    let top = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
    top.press(
      forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 600)),
      withVelocity: .fast, thenHoldForDuration: 0)
    assertGone(sheet, "the sign-in sheet after it was pulled down")
    XCTAssertTrue(overview.exists, "back on the Overview it was opened from")
    XCTAssertTrue(
      app.staticTexts["Already use QuotaBar?"].exists, "the invitation is still offered")
    XCTAssertTrue(invitation.exists, "Sign in to Quota is still offered")
    XCTAssertFalse(
      app.descendants(matching: .any)["connect.connecting"].exists,
      "dismissing started no sign-in"
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

  /// The period menu really changes the period: Today is what the menu then says, a custom range
  /// picked in the sheet is applied, the sheet goes, and the headline and title are that range's.
  func testUsagePeriodSelectsTodayThenAppliesCustomRange() throws {
    let app = launch(fixture: "content", route: "usage")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 10),
      "usage.root"
    )
    selectLast30DaysIfNeeded(app)
    let tokens = app.descendants(matching: .any)["usage.headline.tokens"].firstMatch
    let title = app.descendants(matching: .any)["usage.period.title"].firstMatch
    XCTAssertTrue(tokens.waitForExistence(timeout: 5), "usage.headline.tokens")
    let last30Tokens = tokens.label

    choosePeriod(app, "Today")
    let todayTokens = waitForChange(of: tokens, from: last30Tokens, "headline on Today")
    XCTAssertEqual(todayTokens, "1,704,620 tokens", "the headline is Today's")
    let todayTitle = title.label

    // A fixed range: August 8 to August 12, 2026. The fixture clock is August 14, 2026 (UTC), so
    // both days are inside the year the picker allows in any time zone, the range is not one a
    // named period covers, and its totals are the fixture's activity days August 9 and 12.
    let custom = app.descendants(matching: .any)["usage.period.custom"].firstMatch
    XCTAssertTrue(custom.waitForExistence(timeout: 5), "Custom range")
    tapToOpen(custom, in: app, "Custom range", destination: "usage.range.from")
    let sheetBar = app.navigationBars["Custom range"].firstMatch
    XCTAssertTrue(sheetBar.waitForExistence(timeout: 5), "Custom range sheet")
    chooseDay(app, picker: "usage.range.from", day: "August 8")
    chooseDay(app, picker: "usage.range.to", day: "August 12")
    let apply = app.buttons["usage.range.apply"].firstMatch
    XCTAssertTrue(apply.waitForExistence(timeout: 5), "Apply")
    guard waitUntilReady(apply, in: app, "Apply", chrome: true) else { return }
    apply.tap()
    assertGone(sheetBar, "the Custom range sheet after Apply")

    let deadline = Date().addingTimeInterval(5)
    while !selectedPeriod(app).contains("Custom"), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTAssertTrue(
      selectedPeriod(app).contains("Custom"),
      "the period menu says Custom range, got \(selectedPeriod(app))"
    )
    XCTAssertNotEqual(title.label, todayTitle, "the title names the custom range")
    XCTAssertTrue(
      title.label.hasPrefix("Aug 8 – Aug 12, 2026"),
      "the title is the chosen range, got \(title.label)"
    )
    // August 9 (200,000 in + 40,000 out) and August 12 (10,000 + 2,000) are the fixture's only
    // activity days in the range.
    let customTokens = waitForChange(of: tokens, from: todayTokens, "headline on the custom range")
    XCTAssertEqual(customTokens, "252,000 tokens", "the headline is the custom range's total")
    XCTAssertNotEqual(customTokens, last30Tokens, "the custom range is not Last 30 days")
  }

  /// Waits for an element's label to differ from `old`, and returns the new label.
  @discardableResult
  private func waitForChange(of element: XCUIElement, from old: String, _ what: String) -> String {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      if element.exists, element.label != old, !element.label.isEmpty { return element.label }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTFail("\(what) did not change from \(old)")
    return element.label
  }

  /// Opens a compact date picker, taps the day whose label ends with `day` (the calendar labels
  /// each day "Saturday, August 8"), and closes the calendar.
  private func chooseDay(_ app: XCUIApplication, picker identifier: String, day: String) {
    let picker = app.datePickers[identifier].firstMatch
    XCTAssertTrue(picker.waitForExistence(timeout: 5), identifier)
    let field = picker.buttons.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5), "\(identifier) field")
    guard waitUntilReady(field, in: app, "\(identifier) field", chrome: true) else { return }
    field.tap()
    let button = app.datePickers.collectionViews.buttons
      .matching(NSPredicate(format: "label ENDSWITH %@", ", \(day)")).firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 5), "\(day) in the \(identifier) calendar")
    guard waitUntilReady(button, in: app, day, chrome: true) else { return }
    button.tap()
    // The calendar is a popover; a tap on the empty form below it closes it, as it does for a
    // person. Nothing under that point is a control.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
    assertGone(button, "the \(identifier) calendar")
    let shown = (field.value as? String) ?? ""
    let short = day.replacingOccurrences(of: "August", with: "Aug")
    XCTAssertTrue(shown.contains(short), "\(identifier) shows \(short), got \(shown)")
  }

  func testUsageOpensActivityPatternsAndReturns() throws {
    let app = launch(fixture: "content")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.root"].waitForExistence(timeout: 10),
      "overview.root"
    )
    try selectTab(app, "Usage", root: "usage.root")
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
    popUsageDestination(app, from: "usage.breakdown")

    openUsageDestination(app, link: "usage.open-patterns", root: "usage.patterns")
    XCTAssertTrue(
      app.navigationBars["Activity patterns"].waitForExistence(timeout: 5)
        || app.staticTexts["Activity patterns"].exists
        || app.descendants(matching: .any)["usage.patterns"].exists,
      "Activity patterns title"
    )
    let viewDay = app.descendants(matching: .any)["usage.activity.view-day"].firstMatch
    if !viewDay.exists {
      scrollToIdentifier(app, "usage.activity.view-day", attempts: 24)
    }
    XCTAssertTrue(viewDay.waitForExistence(timeout: 5), "View day")
    tapToOpen(viewDay, in: app, "View day", destination: "usage.day")
    let day = app.descendants(matching: .any)["usage.day"].firstMatch
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.day.model"].waitForExistence(timeout: 5),
      "usage.day.model"
    )
    // The sheet is gone before the navigation bar underneath it is asked to go back.
    let done = app.buttons["Done"].firstMatch
    guard waitUntilReady(done, in: app, "Done", chrome: true) else { return }
    done.tap()
    assertGone(day, "the day sheet after Done")
    popUsageDestination(app, from: "usage.patterns")
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.root"].waitForExistence(timeout: 5),
      "usage.root after back"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["usage.open-patterns"].waitForExistence(timeout: 5),
      "Activity patterns row after back"
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
    XCTAssertFalse(
      app.navigationBars.buttons["Log Out"].exists,
      "Log Out belongs on Settings, not the Overview toolbar"
    )
    let today = app.descendants(matching: .any)["overview.today"].firstMatch
    if !today.exists {
      scrollToIdentifier(app, "overview.today")
    }
    XCTAssertTrue(today.waitForExistence(timeout: 5), "overview.today")
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.today.tokens"].exists,
      "overview.today.tokens"
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["overview.today.cost"].exists,
      "overview.today.cost"
    )
    tapToOpen(today, in: app, "overview.today", destination: "usage.root")
    let period = app.descendants(matching: .any)["usage.period"].firstMatch
    XCTAssertTrue(period.waitForExistence(timeout: 5), "usage period menu")
    XCTAssertTrue(
      period.label.contains("Today") || ((period.value as? String) ?? "").contains("Today"),
      "Overview Today opens the Today period, got \(period.label) / \(String(describing: period.value))"
    )

    try selectTab(app, "Quota", root: "overview.root")
    let card = app.descendants(matching: .any)["overview.subscription"].firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 5), "overview.subscription")
    tapToOpen(card, in: app, "overview.subscription", destination: "subscription.detail")
    let detail = app.descendants(matching: .any)["subscription.detail"]
    // The detail is two groups: what the quota is, and what read it.
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
        || app.descendants(matching: .any)["subscription.sources"].exists,
      "Readings"
    )
    popBack(app, from: "subscription.detail", to: "overview.root", backTitle: "Quota")
    XCTAssertFalse(detail.exists, "subscription detail is dismissed after back")
  }

  /// The Settings hub reaches each pushed destination and comes back to the hub, and Log Out stays
  /// on the hub. What each destination says — About's copy and links included — is the census's
  /// (`QuotaScreenUITests.testSettings…Screen`); this holds the controls a destination exists
  /// for.
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
      assertDestinationControls(app, root: root)
      popSettingsDestination(app, from: root)
      XCTAssertFalse(
        app.descendants(matching: .any)[root].exists,
        "\(root) is dismissed after back"
      )
    }
    // Both account actions are on the hub, and Log Out is the button it says it is: an identifier
    // on a row whose title moved elsewhere would otherwise pass.
    let deleteAccount = app.descendants(matching: .any)["settings.delete-account"]
    if !deleteAccount.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "settings.delete-account", attempts: 12)
    }
    XCTAssertTrue(
      deleteAccount.exists || app.buttons["Delete Account…"].exists,
      "Delete Account…"
    )
    scrollToIdentifier(app, "settings.logout", attempts: 12)
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.logout"].waitForExistence(timeout: 5),
      "Log Out stays on the hub"
    )
    XCTAssertTrue(app.buttons["Log Out"].exists, "Log Out")
  }

  /// What each Settings destination promises once it is open. Copy and pictures are the census's
  /// job; these are the controls the destination exists for.
  private func assertDestinationControls(_ app: XCUIApplication, root: String) {
    switch root {
    case "settings.notifications.root":
      XCTAssertTrue(
        app.switches["Enable Notifications"].waitForExistence(timeout: 5),
        "Enable Notifications"
      )
      XCTAssertTrue(app.switches["Reset Reminders"].exists, "Reset Reminders")
    case "settings.appearance.root":
      XCTAssertTrue(
        app.descendants(matching: .any)["settings.appearance.system"].waitForExistence(timeout: 5),
        "System"
      )
      XCTAssertTrue(app.descendants(matching: .any)["settings.appearance.light"].exists, "Light")
      XCTAssertTrue(app.descendants(matching: .any)["settings.appearance.dark"].exists, "Dark")
    case "settings.about.root":
      // About is words and links; the census reads them. Reaching it and coming back is the
      // journey.
      break
    default:
      XCTFail("no controls named for \(root)")
    }
  }

  /// A stored provider session the provider refused offers the one action that fixes it, and says
  /// so. This asserts the affordance, not a provider login: the sign-in it starts leaves the
  /// fixture. The rest of the Providers matrix — Remove, Connect, Add Account — is the census's
  /// (`QuotaScreenUITests.testProvidersMatrixScreen`).
  func testRefusedProviderSessionOffersSignInAgain() throws {
    let app = launch(fixture: "providers", route: "settings")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
      "settings.root"
    )
    let refused = app.descendants(matching: .any)["providers.session.codex:codex_personal"]
    if !refused.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "providers.session.codex:codex_personal", attempts: 12)
    }
    XCTAssertTrue(refused.waitForExistence(timeout: 5), "refused Codex session")
    let again = app.descendants(matching: .any)["providers.signin-again.codex:codex_personal"]
      .firstMatch
    if !again.exists {
      scrollToIdentifier(app, "providers.signin-again.codex:codex_personal", attempts: 8)
    }
    XCTAssertTrue(again.waitForExistence(timeout: 5), "Sign in again affordance")
    waitUntilReady(again, in: app, "Sign in again")
    XCTAssertTrue(
      app.staticTexts["Sign in again to keep reading this account."].exists,
      "refused session says what to do"
    )
  }

  /// A phone that only reads its own providers still has a quota screen, no managed Today, and no
  /// account-only Devices row in Settings.
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
    // The identifier and the words both: a Today section that lost its identifier is still a
    // Today section this phone has no account to fill.
    XCTAssertFalse(app.staticTexts["Today"].exists, "no Today section without an account")
    XCTAssertFalse(
      app.descendants(matching: .any)["overview.empty"].exists,
      "not the empty state"
    )
    XCTAssertFalse(app.staticTexts["No quota yet"].exists, "not the empty state")

    // Its own reading opens its detail and comes back. What the detail says — remaining history,
    // the sources that read it — is the census's (`testLocalOnlySubscriptionDetailScreen`).
    let card = app.descendants(matching: .any)["overview.subscription"].firstMatch
    tapToOpen(card, in: app, "overview.subscription", destination: "subscription.detail")
    popBack(app, from: "subscription.detail", to: "overview.root", backTitle: "Quota")
    XCTAssertTrue(card.waitForExistence(timeout: 5), "this iPhone's own reading after back")

    // Devices are the Account's: without one the Settings hub has no Devices row either; the
    // sign-in card already covers it.
    try selectTab(app, "Settings", root: "settings.root")
    XCTAssertFalse(
      app.descendants(matching: .any)["settings.devices"].exists,
      "Devices row is absent when signed out"
    )
  }

  /// The seven essential values at `accessibilityExtraLarge`, where a fixed-height row or a
  /// `lineLimit(1)` would truncate them: they exist, are hittable, carry their whole label, and
  /// sit on screen.
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
    popSettingsDestination(app, from: "settings.about.root")
    XCTAssertFalse(
      app.descendants(matching: .any)["settings.about.root"].exists,
      "About is dismissed after back"
    )
  }

  /// Each value is asserted by name, so the one a size truncates fails by name.
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
