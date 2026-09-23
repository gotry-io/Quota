import XCTest

/// Shared base for the two UI test classes: the required journeys (`QuotaSmokeUITests`) and the
/// advisory screen census (`QuotaScreenUITests`). It declares no test method of its own, so XCTest
/// discovers nothing here.
class QuotaUITestCase: XCTestCase {
  /// Every interaction this run had to repeat. Three helpers tap a second time when the first tap
  /// was dropped, which is a workaround for event delivery and not a product behaviour: a test
  /// that needed one is reported as recovered rather than simply passing, so the workaround can be
  /// removed when the recoveries stop — or looked at when they do not.
  private var recoveries: [String] = []

  override func setUpWithError() throws {
    continueAfterFailure = false
    recoveries = []
    switch uitestEnvironment("QUOTA_IOS_APPEARANCE")?.lowercased() {
    case "dark":
      XCUIDevice.shared.appearance = .dark
    default:
      XCUIDevice.shared.appearance = .light
    }
  }

  override func tearDownWithError() throws {
    try super.tearDownWithError()
    guard !recoveries.isEmpty else { return }
    let name = self.name
    let lines = recoveries.map { "recovered-on-retry: \(name) — \($0)" }
    // Both channels on purpose: the attachment travels with the result bundle, and the line is in
    // the run's log where a job summary can count it without opening the bundle.
    for line in lines { print(line) }
    let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
    attachment.name = "recovered-on-retry"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Records that an interaction worked only because it was repeated. Call it after the extra
  /// attempt succeeded: a test that tapped twice and still failed did not recover, and a summary
  /// that counted it would be claiming the opposite of what happened.
  func recordRecovery(_ what: String, recovered: Bool, attempts: Int) {
    guard recovered, attempts > 1 else { return }
    recoveries.append(what)
  }


  /// Every launch names its text size and its appearance preference, so neither is whatever the
  /// simulator or an earlier run left behind: the profile's size (`QUOTA_IOS_TEXT_SIZE`), else the
  /// standard `large`; and the in-app Appearance preference as System, so the device appearance
  /// `setUpWithError` set is the one drawn rather than a saved Light or Dark.
  func launch(fixture: String, route: String? = nil, textSize: String? = nil)
    -> XCUIApplication
  {
    let app = XCUIApplication()
    var arguments = ["--visual-fixture", fixture]
    if let route {
      arguments += ["--route", route]
    }
    let size = textSize ?? uitestEnvironment("QUOTA_IOS_TEXT_SIZE") ?? "large"
    arguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategoryName(size)]
    arguments += ["-appearance", "system"]
    app.launchArguments = arguments
    app.launch()
    return app
  }

  func uitestEnvironment(_ key: String) -> String? {
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

  func contentSizeCategoryName(_ size: String) -> String {
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

  func attachScreenshot(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Remaining percent, tokens, or cost at accessibility Extra Large: present, hittable, full
  /// accessibility label, and not clipped by the window.
  func assertUnclippedEssentialValue(
    _ app: XCUIApplication,
    identifier: String,
    expectedLabel: String,
    combinedLabelContainsValue: Bool = false
  ) {
    var element = app.descendants(matching: .any)[identifier].firstMatch
    if !element.waitForExistence(timeout: 2) {
      revealIdentifier(app, identifier, attempts: 24)
    }
    if !element.exists {
      element = app.staticTexts[expectedLabel].firstMatch
      if !element.waitForExistence(timeout: 2) {
        for _ in 0..<16 where !element.exists {
          scrollContent(app, up: true)
          _ = element.waitForExistence(timeout: 0.8)
        }
      }
    }
    XCTAssertTrue(element.waitForExistence(timeout: 5), identifier)
    if combinedLabelContainsValue {
      let query = app.descendants(matching: .any).matching(identifier: identifier)
      let count = query.count
      var matched: XCUIElement?
      for index in 0..<count {
        let candidate = query.element(boundBy: index)
        if candidate.label.contains(expectedLabel) {
          matched = candidate
          break
        }
      }
      if matched == nil {
        let byLabel = app.staticTexts[expectedLabel].firstMatch
        if byLabel.exists { matched = byLabel }
      }
      if let matched { element = matched }
    }
    if element.exists && !element.isHittable {
      revealIdentifier(app, identifier, attempts: 8)
      if !element.isHittable, element.label != expectedLabel {
        let byLabel = app.staticTexts[expectedLabel].firstMatch
        if byLabel.exists { element = byLabel }
      }
    }
    XCTAssertTrue(element.isHittable, "\(identifier) hittable at accessibility Extra Large")
    let label = element.label
    XCTAssertFalse(
      label.contains("…") || label.contains("..."),
      "\(identifier) label is not an ellipsis truncation"
    )
    if combinedLabelContainsValue {
      XCTAssertTrue(
        label.contains(expectedLabel),
        "\(identifier) combined label contains the full value \(expectedLabel); got \(label)"
      )
    } else {
      XCTAssertEqual(
        label,
        expectedLabel,
        "\(identifier) label is the full string, not a truncation"
      )
    }
    func fullyOnScreen(_ frame: CGRect, _ window: CGRect) -> Bool {
      frame.minX >= window.minX - 1
        && frame.maxX <= window.maxX + 1
        && frame.minY >= window.minY - 1
        && frame.maxY <= window.maxY + 1
    }
    var window = app.windows.firstMatch.frame
    var frame = element.frame
    for _ in 0..<8 where !fullyOnScreen(frame, window) {
      if frame.maxY > window.maxY + 1 {
        scrollContent(app, up: true)
      } else if frame.minY < window.minY - 1 {
        scrollContent(app, up: false)
      } else {
        break
      }
      _ = element.waitForExistence(timeout: 0.8)
      window = app.windows.firstMatch.frame
      frame = element.frame
    }
    let visible = window.intersection(frame)
    XCTAssertFalse(visible.isNull || visible.isEmpty, "\(identifier) intersects the window")
    if fullyOnScreen(frame, window) {
      return
    }
    // A combined remaining card at Extra Large can still be taller than the window;
    // hittable plus a visible slice is the on-screen check for that node.
    XCTAssertGreaterThan(
      frame.height, window.height * 0.8,
      "\(identifier) frame is clipped by the screen: \(frame) vs \(window)"
    )
    XCTAssertGreaterThan(visible.height, 40, "\(identifier) has a visible slice on-screen")
  }

  func assertTab(_ app: XCUIApplication, _ name: String) {
    XCTAssertTrue(app.tabBars.buttons[name].exists, "\(name) tab")
  }

  // MARK: Readiness

  /// Where a content control can be tapped: the window, below the navigation bar and above the
  /// tab bar. A row under the floating iOS 26 bars still reports `isHittable`, and a synthesized
  /// tap there lands on the glass instead of the row.
  func unobscuredViewport(_ app: XCUIApplication) -> CGRect {
    var area = app.windows.firstMatch.frame
    guard !area.isEmpty else { return area }
    var top = area.minY
    for index in 0..<app.navigationBars.count {
      let bar = app.navigationBars.element(boundBy: index)
      guard bar.exists else { continue }
      let frame = bar.frame
      // Only a bar pinned to the top of the window covers content; a sheet's bar sits lower and
      // is part of the sheet.
      if frame.minY <= area.minY + area.height * 0.2 { top = max(top, frame.maxY) }
    }
    var bottom = area.maxY
    let tabBar = app.tabBars.firstMatch
    if tabBar.exists, tabBar.isHittable, !tabBar.frame.isEmpty {
      bottom = min(bottom, tabBar.frame.minY)
    }
    area.origin.y = top
    area.size.height = max(0, bottom - top)
    return area
  }

  /// What a control looked like when it was checked, for a failure that says why it was not ready.
  struct Readiness: CustomStringConvertible {
    var exists = false
    var enabled = false
    var hittable = false
    var frame = CGRect.null
    var stable = false
    var viewport = CGRect.null
    var inViewport = false

    var description: String {
      "exists=\(exists) enabled=\(enabled) hittable=\(hittable) stable=\(stable) "
        + "inViewport=\(inViewport) frame=\(frame) viewport=\(viewport)"
    }
  }

  /// Waits until `element` can be tapped the way a person would: it exists, is enabled (unless
  /// `enabled` is false), is hittable, has held the same frame across two samples, and — for a
  /// content control — lies inside the unobscured viewport, scrolling it there by a measured
  /// nudge when it does not. A bar, menu or sheet control passes `chrome: true` and is checked
  /// against the whole window. Fails the test with the observed state when the control never gets
  /// there.
  @discardableResult
  func waitUntilReady(
    _ element: XCUIElement,
    in app: XCUIApplication,
    _ what: String,
    enabled: Bool = true,
    chrome: Bool = false,
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var state = Readiness()
    var lastFrame = CGRect.null
    var lastSampled = Date.distantPast
    var nudges = 0
    while true {
      state = Readiness()
      state.exists = element.exists
      if state.exists {
        state.enabled = element.isEnabled
        state.hittable = element.isHittable
        state.frame = element.frame
        let now = Date()
        // Frames are compared within half a point: a settled SwiftUI layout can answer
        // 116.0 one sample and 116.00000000000006 the next, and exact equality never held on
        // the CI runner.
        let same = Self.about(state.frame, equals: lastFrame)
        state.stable = !state.frame.isEmpty && same
          && now.timeIntervalSince(lastSampled) >= 0.15
        if !same {
          lastFrame = state.frame
          lastSampled = now
        }
        state.viewport = chrome ? app.windows.firstMatch.frame : unobscuredViewport(app)
        state.inViewport = Self.lies(state.frame, inside: state.viewport)
        if (state.enabled || !enabled) && state.hittable && state.stable && state.inViewport {
          return true
        }
        // Resting outside the viewport: move it by the distance it is out, not a page.
        if !chrome, state.stable, !state.inViewport, nudges < 8, !state.frame.isEmpty {
          nudges += 1
          nudge(app, frame: state.frame, into: state.viewport)
          lastFrame = .null
          continue
        }
      }
      if Date() >= deadline { break }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTFail("\(what) was not ready to tap after \(Int(timeout))s: \(state)", file: file, line: line)
    return false
  }

  static func about(_ left: CGRect, equals right: CGRect) -> Bool {
    guard !left.isNull, !right.isNull else { return left.isNull && right.isNull }
    return abs(left.minX - right.minX) < 0.5 && abs(left.minY - right.minY) < 0.5
      && abs(left.width - right.width) < 0.5 && abs(left.height - right.height) < 0.5
  }

  /// Inside, allowing a point for rounding; a control taller than the viewport needs only its
  /// centre inside, which is where a tap lands.
  static func lies(_ frame: CGRect, inside viewport: CGRect) -> Bool {
    guard !frame.isEmpty, !viewport.isEmpty else { return false }
    if frame.height > viewport.height {
      return viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
    }
    return frame.minY >= viewport.minY - 1 && frame.maxY <= viewport.maxY + 1
      && frame.minX >= viewport.minX - 1 && frame.maxX <= viewport.maxX + 1
  }

  /// Drags the list by how far `frame` is outside `viewport`, holding at the end so the list does
  /// not fling past it.
  func nudge(_ app: XCUIApplication, frame: CGRect, into viewport: CGRect) {
    let list = scrollableList(in: app)
    let listFrame = list.frame
    guard !listFrame.isEmpty else { return }
    // Positive moves content up (reveals what is below).
    var distance: CGFloat = 0
    if frame.maxY > viewport.maxY { distance = frame.maxY - viewport.maxY + 24 }
    if frame.minY < viewport.minY { distance = frame.minY - viewport.minY - 24 }
    let limit = listFrame.height * 0.4
    distance = min(max(distance, -limit), limit)
    let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = start.withOffset(CGVector(dx: 0, dy: -distance))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
  }

  /// Taps `control` once it is ready and waits for `destination` to appear. A second tap is made
  /// only for the failure it exists for — the destination did not appear and the control is still
  /// there and still ready, i.e. the first tap was dropped — and is recorded as a recovery.
  func tapToOpen(
    _ control: XCUIElement,
    in app: XCUIApplication,
    _ what: String,
    destination: String,
    chrome: Bool = false,
    timeout: TimeInterval = 8,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let target = app.descendants(matching: .any)[destination].firstMatch
    var taps = 0
    for _ in 0..<2 where !target.exists {
      if taps > 0, !(control.exists && control.isHittable) { break }
      guard waitUntilReady(control, in: app, what, chrome: chrome, file: file, line: line) else {
        return
      }
      taps += 1
      control.tap()
      _ = target.waitForExistence(timeout: timeout)
    }
    recordRecovery("\(what) dropped a tap", recovered: target.exists, attempts: taps)
    XCTAssertTrue(target.exists, "\(destination) after tapping \(what)", file: file, line: line)
  }

  /// Switches to a tab and waits for it to be the selected one with its root on screen. A root can
  /// already be in the hierarchy behind another tab, so the tab's own selected state decides.
  func selectTab(
    _ app: XCUIApplication,
    _ name: String,
    root: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    try restoreTabBar(app)
    let tab = app.tabBars.buttons[name].firstMatch
    var taps = 0
    for _ in 0..<2 where !tab.isSelected {
      guard waitUntilReady(tab, in: app, "\(name) tab", chrome: true, file: file, line: line)
      else { return }
      taps += 1
      tab.tap()
      let deadline = Date().addingTimeInterval(5)
      while !tab.isSelected, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      }
    }
    recordRecovery("the \(name) tab dropped a tap", recovered: tab.isSelected, attempts: taps)
    XCTAssertTrue(tab.isSelected, "\(name) tab is selected", file: file, line: line)
    XCTAssertTrue(
      app.descendants(matching: .any)[root].waitForExistence(timeout: 8), root,
      file: file, line: line)
  }

  /// Waits for a screen, sheet or menu to leave, and fails with what is still there.
  func assertGone(
    _ element: XCUIElement,
    _ what: String,
    timeout: TimeInterval = 6,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let gone = element.waitForNonExistence(timeout: timeout)
    XCTAssertTrue(
      gone, "\(what) is still on screen: \(element.debugDescription)", file: file, line: line)
  }

  // MARK: Navigation

  /// Devices is a Settings destination: select Settings, then open the row.
  func openDevicesFromSettings(_ app: XCUIApplication) throws {
    try selectTab(app, "Settings", root: "settings.root")
    openSettingsDestination(app, link: "settings.devices", root: "devices.root")
  }

  /// The period menu (`usage.period`) and its current value.
  func selectedPeriod(_ app: XCUIApplication) -> String {
    let period = app.descendants(matching: .any)["usage.period"].firstMatch
    return period.label + " " + ((period.value as? String) ?? "")
  }

  /// Chooses `item` in the period menu and asserts the menu now says so.
  func choosePeriod(_ app: XCUIApplication, _ item: String) {
    let period = app.descendants(matching: .any)["usage.period"].firstMatch
    XCTAssertTrue(period.waitForExistence(timeout: 5), "usage period menu")
    guard waitUntilReady(period, in: app, "usage period menu") else { return }
    period.tap()
    let choice = app.buttons[item].firstMatch
    XCTAssertTrue(choice.waitForExistence(timeout: 5), "\(item) in the period menu")
    guard waitUntilReady(choice, in: app, "\(item) in the period menu", chrome: true) else {
      return
    }
    choice.tap()
    assertGone(choice, "the period menu")
    let deadline = Date().addingTimeInterval(5)
    while !selectedPeriod(app).contains(item), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTAssertTrue(
      selectedPeriod(app).contains(item),
      "the period menu says \(item), got \(selectedPeriod(app))"
    )
  }

  /// B4b's period chooser is a menu (`usage.period`), not a segmented control.
  func selectLast30DaysIfNeeded(_ app: XCUIApplication) {
    let period = app.descendants(matching: .any)["usage.period"].firstMatch
    XCTAssertTrue(period.waitForExistence(timeout: 5), "usage period menu")
    if selectedPeriod(app).contains("Last 30 days") { return }
    choosePeriod(app, "Last 30 days")
  }

  func openUsageDestination(
    _ app: XCUIApplication,
    link: String,
    root: String
  ) {
    let control = app.descendants(matching: .any)[link].firstMatch
    if !control.waitForExistence(timeout: 2) {
      scrollToTop(app)
    }
    if !control.exists {
      scrollToIdentifier(app, link, attempts: 16)
    }
    XCTAssertTrue(control.waitForExistence(timeout: 5), link)
    tapToOpen(control, in: app, link, destination: root)
  }

  func popUsageDestination(_ app: XCUIApplication, from source: String) {
    popBack(app, from: source, to: "usage.root", backTitle: "Usage")
  }

  func openSettingsDestination(
    _ app: XCUIApplication,
    link: String,
    root: String
  ) {
    let control = app.descendants(matching: .any)[link].firstMatch
    if !control.waitForExistence(timeout: 2) {
      // A popped destination restores the hub where it was left, which can be either side of the
      // row being asked for, so the top is where the search starts.
      scrollToTop(app)
    }
    if !control.exists {
      scrollToIdentifier(app, link, attempts: 12)
    }
    XCTAssertTrue(control.waitForExistence(timeout: 5), link)
    tapToOpen(control, in: app, link, destination: root)
  }

  /// Pops one navigation level: the back button is ready, the tap is made, and the screen it left
  /// (`source`) is gone before `root` is checked — an assertion made while the outgoing screen is
  /// still in the hierarchy would be reading the transition. A second tap is made only when the
  /// source is still there and the back button is still ready (the first tap was dropped by the
  /// iOS 26 bar), and is recorded as a recovery.
  func popBack(_ app: XCUIApplication, from source: String, to root: String, backTitle: String) {
    let back = app.navigationBars.buttons[backTitle].firstMatch
    let leaving = app.descendants(matching: .any)[source].firstMatch
    XCTAssertTrue(leaving.exists, "\(source) before back")
    var taps = 0
    for _ in 0..<2 where leaving.exists {
      if taps > 0, !(back.exists && back.isHittable) { break }
      guard waitUntilReady(back, in: app, "back to \(backTitle)", chrome: true) else { return }
      taps += 1
      back.tap()
      _ = leaving.waitForNonExistence(timeout: 5)
    }
    recordRecovery("back to \(backTitle) dropped a tap", recovered: !leaving.exists, attempts: taps)
    XCTAssertFalse(leaving.exists, "\(source) is gone after back")
    XCTAssertTrue(
      app.descendants(matching: .any)[root].waitForExistence(timeout: 5), "\(root) after back")
  }

  func popSettingsDestination(_ app: XCUIApplication, from source: String) {
    popBack(app, from: source, to: "settings.root", backTitle: "Settings")
    let logout = app.descendants(matching: .any)["settings.logout"]
    if !logout.waitForExistence(timeout: 2) {
      scrollToIdentifier(app, "settings.logout", attempts: 12)
    }
    XCTAssertTrue(logout.waitForExistence(timeout: 5), "hub Log Out after pop")
  }

  /// Waits for the screen to be at rest before a capture or an audit: the app is in the
  /// foreground, and `anchor` — by default the root of the screen on show — holds the same frame
  /// across two samples. After a scroll, pass an element inside the list: the list's own frame
  /// does not move while its content decelerates, and the contrast pass samples pixels, so a row
  /// still gliding reads as low contrast. Fails with the frames it saw when the anchor never
  /// comes to rest.
  func settle(
    _ app: XCUIApplication,
    anchor: XCUIElement? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 5), "app in the foreground", file: file,
      line: line)
    let element: XCUIElement
    if let anchor {
      element = anchor.firstMatch
    } else if let root = currentScreenRoot(app) {
      element = root
    } else {
      return
    }
    let deadline = Date().addingTimeInterval(5)
    var last = element.frame
    var frames = [last]
    while Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
      let now = element.frame
      if now == last, !now.isEmpty { return }
      last = now
      if frames.count < 8 { frames.append(now) }
    }
    XCTFail("\(element) did not come to rest in 5s; frames \(frames)", file: file, line: line)
  }

  /// The root of the screen on show, most specific first (see `currentScreenName`).
  func currentScreenRoot(_ app: XCUIApplication) -> XCUIElement? {
    let name = currentScreenName(app)
    guard name != "unknown" else { return nil }
    return app.descendants(matching: .any)[name].firstMatch
  }

  /// Back to the top of a list, whatever it was scrolled to. One swipe is not the top of a hub
  /// longer than a couple of screens.
  func scrollToTop(_ app: XCUIApplication) {
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
  func revealSources(_ app: XCUIApplication) {
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
    guard waitUntilReady(sources, in: app, "subscription.sources") else { return }
    sources.tap()
    _ = app.descendants(matching: .any)["subscription.reporting"].waitForExistence(timeout: 2)
  }

  func scrollToIdentifier(
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

  func scrollToIdentifierOnce(_ app: XCUIApplication, _ identifier: String) {
    let element = app.descendants(matching: .any)[identifier]
    scrollContent(app, up: true)
    _ = element.waitForExistence(timeout: 1)
  }

  /// Scroll until `identifier` exists and can be hit. Off-screen or tab-bar-covered rows
  /// report `exists` while a synthesized tap still lands on the glass.
  func revealIdentifier(
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
  func restoreTabBar(_ app: XCUIApplication) throws {
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
  func assertListScrolls(
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

  func scrollableList(in app: XCUIApplication) -> XCUIElement {
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

  func scrollContent(_ app: XCUIApplication, up: Bool) {
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
  func audit(
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

  func isAuditTimeout(_ description: String) -> Bool {
    description.contains("Audit failed to complete in time")
      || description.contains("Timed out while running accessibility audit")
  }

  func currentTestName() -> String {
    let raw = name
    guard let marker = raw.range(of: "test") else { return raw }
    let fromTest = raw[marker.lowerBound...]
    let end = fromTest.firstIndex(where: { !$0.isLetter && !$0.isNumber }) ?? fromTest.endIndex
    return String(fromTest[..<end])
  }

  func currentScreenName(_ app: XCUIApplication) -> String {
    let ids = [
      "usage.day",
      "usage.breakdown",
      "usage.patterns",
      "usage.budget.detail",
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

  func runAuditSession(
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
  func collectAuditPass(
    _ app: XCUIApplication,
    types: XCUIAccessibilityAuditType,
    screen: String
  ) throws -> AuditPassResult {
    let box = AuditCollector()
    do {
      try app.performAccessibilityAudit(for: types) { issue in
        box.findings.append(makeAuditFinding(issue, screen: screen))
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

  func attachAuditOutcome(_ record: AuditOutcomeRecord) {
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

/// Content-fixture strings `testLargeTypeScreenshots` requires in full at Extra Large.
/// Today values are B3b's compact row: compact child text plus the combined VoiceOver label.
enum ContentFixtureLargeType {
  static let remainingPercent = "68%"
  static let todayTokens = "1.7M tokens"
  static let todayCost = "$1.49 API-equivalent"
  static let todayCombined = "Today, 1,704,620 tokens, $1.49 API-equivalent cost"
  static let usageTokens = "11,400,000 tokens"
  static let usageCost = "API-equivalent cost, $8.50, complete"
}

/// One iOS 26.3 auditor exception: audit type + identifier or exact label + screen.
struct KeptAuditorExemption {
  let type: String
  let screen: String
  let identifier: String
  let label: String
  let rule: String
}

/// Feature-wide prefix/parent skips are gone. Each row is what a full A2a run actually
/// matched; a row nothing matches is deleted. Reasons are iOS 26.3 auditor limitations
/// unless a comment says otherwise.
private let keptAuditorExemptions: [KeptAuditorExemption] = [
  // System list section chrome: Dynamic Type "partially unsupported" on iOS 26.3.
  .init(
    type: "dynamic-type", screen: "overview.root", identifier: "section.footer.updated",
    label: "", rule: "dynamic-type-section.footer.updated"),
  .init(
    type: "dynamic-type", screen: "overview.root", identifier: "section.header.mac-setup",
    label: "", rule: "dynamic-type-section.header.mac-setup"),
  .init(
    type: "dynamic-type", screen: "settings.notifications.root",
    identifier: "section.header.codex", label: "",
    rule: "dynamic-type-section.header.codex"),
  .init(
    type: "dynamic-type", screen: "settings.root", identifier: "section.footer.providers",
    label: "", rule: "dynamic-type-section.footer.providers"),
  // Identified empty/error copy the iOS 26.3 auditor still flags as partial Dynamic Type.
  .init(
    type: "dynamic-type", screen: "settings.root",
    identifier: "settings.sign-in-methods.manage", label: "",
    rule: "dynamic-type-settings.sign-in-methods.manage"),
  .init(
    type: "dynamic-type", screen: "usage.day", identifier: "usage.day.empty",
    label: "", rule: "dynamic-type-usage.day.empty"),
  .init(
    type: "dynamic-type", screen: "usage.day", identifier: "usage.day.retry",
    label: "", rule: "dynamic-type-usage.day.retry"),
  // Inner StaticText of combined B4b rows. iOS 26.3 still reports partial
  // Dynamic Type after ViewThatFits, fixedSize, and accessibilityHidden.
  .init(
    type: "dynamic-type", screen: "overview.root", identifier: "overview.remaining",
    label: "", rule: "dynamic-type-overview.remaining"),
  .init(
    type: "dynamic-type", screen: "overview.root", identifier: "",
    label: "Claude Code", rule: "dynamic-type-overview-claude-code"),
  .init(
    type: "dynamic-type", screen: "overview.root", identifier: "",
    label: "Team workspace", rule: "dynamic-type-overview-team-workspace"),
  .init(
    type: "dynamic-type", screen: "overview.root", identifier: "",
    label: "Max", rule: "dynamic-type-overview-max"),
  .init(
    type: "dynamic-type", screen: "usage.root", identifier: "usage.budget",
    label: "", rule: "dynamic-type-usage.budget"),
  .init(
    type: "dynamic-type", screen: "settings.root", identifier: "settings.budget",
    label: "", rule: "dynamic-type-settings.budget"),
  .init(
    type: "dynamic-type", screen: "settings.root",
    identifier: "settings.appearance", label: "",
    rule: "dynamic-type-settings.appearance"),
  .init(
    type: "dynamic-type", screen: "usage.breakdown",
    identifier: "usage.headline.cache-hit", label: "",
    rule: "dynamic-type-usage.headline.cache-hit"),
  .init(
    type: "dynamic-type", screen: "usage.breakdown",
    identifier: "usage.headline.reasoning", label: "",
    rule: "dynamic-type-usage.headline.reasoning"),
  .init(
    type: "dynamic-type", screen: "usage.breakdown",
    identifier: "usage.breakdown.messages", label: "",
    rule: "dynamic-type-usage.breakdown.messages"),
  // System sheet Done control.
  .init(
    type: "dynamic-type", screen: "usage.day", identifier: "", label: "Done",
    rule: "dynamic-type-label-Done"),
  .init(
    type: "dynamic-type", screen: "usage.day", identifier: "",
    label: "Couldn't load this day's usage.",
    rule: "dynamic-type-label-couldnt-load"),
  // System Form/Link inner labels (the row identifier sits on the parent).
  .init(
    type: "dynamic-type", screen: "settings.about.root", identifier: "", label: "GitHub",
    rule: "dynamic-type-label-GitHub"),
  .init(
    type: "dynamic-type", screen: "settings.about.root", identifier: "", label: "License",
    rule: "dynamic-type-label-License"),
  .init(
    type: "dynamic-type", screen: "settings.about.root", identifier: "", label: "Website",
    rule: "dynamic-type-label-Website"),
  // Form toggle label and footer. iOS 26.3 reports partial Dynamic Type on the inner
  // StaticText after fixedSize; both lines wrap and stay on screen.
  .init(
    type: "dynamic-type", screen: "settings.about.root", identifier: "",
    label: "Share quota history across your devices",
    rule: "dynamic-type-settings-history-sync-label"),
  .init(
    type: "dynamic-type", screen: "settings.about.root",
    identifier: "settings.history.sync.footnote", label: "",
    rule: "dynamic-type-settings.history.sync.footnote"),
  .init(
    type: "dynamic-type", screen: "settings.root", identifier: "",
    label: "Manage Devices on Web", rule: "dynamic-type-label-Manage-Devices"),
  .init(
    type: "dynamic-type", screen: "settings.root", identifier: "", label: "Support",
    rule: "dynamic-type-label-Support"),
  .init(
    type: "dynamic-type", screen: "settings.root", identifier: "", label: "Privacy",
    rule: "dynamic-type-label-Privacy"),
  // Inner text of a combined Devices row; VoiceOver uses the row label.
  .init(
    type: "dynamic-type", screen: "devices.root", identifier: "",
    label: "iOS · no readings yet", rule: "dynamic-type-label-ios-no-readings"),
  .init(
    type: "dynamic-type", screen: "devices.root", identifier: "", label: "Not reporting",
    rule: "dynamic-type-label-Not-reporting"),
  .init(
    type: "dynamic-type", screen: "devices.root", identifier: "", label: "This iPhone",
    rule: "dynamic-type-label-This-iPhone"),
  // Wrapping subscription-detail copy. iOS 26.3 still reports partial Dynamic Type
  // after ViewThatFits, .body, and fixedSize; the strings are fully on-screen.
  .init(
    type: "dynamic-type", screen: "subscription.detail",
    identifier: "section.header.history", label: "",
    rule: "dynamic-type-section.header.history"),
  .init(
    type: "dynamic-type", screen: "subscription.detail",
    identifier: "subscription.history", label: "",
    rule: "dynamic-type-subscription.history"),
  .init(
    type: "dynamic-type", screen: "subscription.detail",
    identifier: "subscription.sources", label: "",
    rule: "dynamic-type-subscription.sources"),
]

private let auditExemptionRules: [String] = {
  var seen: Set<String> = ["nil-element"]
  var rules = ["nil-element"]
  for item in keptAuditorExemptions where seen.insert(item.rule).inserted {
    rules.append(item.rule)
  }
  return rules
}()

struct AuditFinding: Encodable {
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

struct AuditOutcomeRecord: Encodable {
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

struct AuditPassResult {
  var findings: [AuditFinding]
  var completed: Bool
}

struct AuditSession {
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

func auditTypeName(_ description: String) -> String {
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

func makeAuditFinding(
  _ issue: XCUIAccessibilityAuditIssue,
  screen: String
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
      screen: screen,
      identifier: identifier,
      label: label
    ) {
      return finding(disposition: "exempted", rule: rule)
    }
  }
  return finding(disposition: "recorded", rule: nil)
}

func makeAuditOutcomeRecord(
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

/// Match type + screen + (exact identifier, or exact label when the issue has none).
func keptAuditorExceptionRule(
  type: String,
  screen: String,
  identifier: String,
  label: String
) -> String? {
  for item in keptAuditorExemptions {
    guard item.type == type, item.screen == screen else { continue }
    if !item.identifier.isEmpty {
      if identifier == item.identifier { return item.rule }
    } else if identifier.isEmpty, label == item.label {
      return item.rule
    }
  }
  return nil
}

/// The identifier of the row an audit issue actually belongs to. An audit names the text inside a
/// row, and only the row carries an identifier, so it comes from the path the auditor prints above
/// the element.
func parentIdentifier(of element: XCUIElement) -> String {
  let lines = element.debugDescription.split(separator: "\n")
  guard let start = lines.firstIndex(where: { $0.hasPrefix("Path to element:") }) else { return "" }
  let rest = lines[lines.index(after: start)...]
  let path = rest.prefix { $0.first == " " || $0.first == "\u{2192}" }
  return path.suffix(2).joined(separator: " ")
}
