import Foundation
import QuotaAlerts
import QuotaPresentation
import QuotaProviderStatus
import QuotaRelay
import QuotaWire
import Testing

@testable import Quota

struct VisualFixtureParserTests {
  @Test
  func parseReturnsNilWhenValueMissingOrUnknown() {
    #expect(VisualFixture.parse(arguments: ["Quota"]) == nil)
    #expect(VisualFixture.parse(arguments: []) == nil)
    #expect(VisualFixture.parse(arguments: ["--visual-fixture"]) == nil)
    #expect(VisualFixture.parse(arguments: ["--visual-fixture", "unknown"]) == nil)
    #expect(VisualFixture.parse(arguments: ["--visual-fixture", "signed_out"]) == nil)
  }

  @Test(
    arguments: [
      ("signed-out", VisualFixture.signedOut),
      ("connecting", VisualFixture.connecting),
      ("connect-error", VisualFixture.connectError),
      ("expired", VisualFixture.expired),
      ("confirm-account", VisualFixture.confirmAccount),
      ("connect-refresh-failed", VisualFixture.connectRefreshFailed),
      ("loading", VisualFixture.loading),
      ("launch", VisualFixture.launch),
      ("updating", VisualFixture.updating),
      ("content", VisualFixture.content),
      ("cached-error", VisualFixture.cachedError),
      ("empty", VisualFixture.empty),
      ("no-devices", VisualFixture.noDevices),
      ("local-only", VisualFixture.localOnly),
      ("merged", VisualFixture.merged),
      ("providers", VisualFixture.providers),
      ("activity-loading", VisualFixture.activityLoading),
      ("activity-failed", VisualFixture.activityFailed),
      ("activity-day-empty", VisualFixture.activityDayEmpty),
      ("activity-day-failed", VisualFixture.activityDayFailed),
      ("sign-in", VisualFixture.signIn),
      ("sign-in-methods", VisualFixture.signInMethods),
    ]
  )
  func parseRecognizesEachFixture(raw: String, expected: VisualFixture) {
    #expect(VisualFixture.parse(arguments: ["Quota", "--visual-fixture", raw]) == expected)
  }
}

#if DEBUG
  @MainActor
  struct VisualFixtureStateTests {
    @Test(arguments: VisualFixture.allCases)
    func everyScenarioStaysOfflineAndDeclaresAValidCombination(fixture: VisualFixture) {
      let now = VisualFixture.referenceDate
      let scenario = VisualScenario.make(fixture, now: now)
      #expect(scenario.validationIssues == [])
      let model = AppModel.visualFixture(fixture, now: now)
      #expect(model.isOfflineFixture)
      #expect(model.skipsRestore)
      #expect(model.displayClock.isFixed)
    }

    /// The same account read by two Macs and by this phone resolves to one row, and this phone's
    /// reading is the newest one, so it is the one shown.
    @Test
    func mergedPrefersThisPhonesNewerReadingAndKeepsEveryDevice() throws {
      let model = AppModel.visualFixture(.merged, now: VisualFixture.referenceDate)
      #expect(model.phase == .signedIn)
      #expect(model.overviewSources == OverviewSources(hasLocal: true, hasAccount: true))
      // One row, not two: the phone and the Macs read the same subscription.
      #expect(model.subscriptions.filter { $0.snapshot.provider == .codex }.count == 1)
      let codex = try #require(model.subscriptions.first { $0.snapshot.provider == .codex })
      #expect(codex.key == "codex|visual_codex|global|")
      #expect(codex.sources.count == 3)
      let readings = SubscriptionDetailContent.make(
        subscription: codex,
        deviceNames: model.readingDeviceNames,
        now: VisualFixture.referenceDate
      )
      #expect(readings.sources.map(\.displayName) == ["This iPhone", "Studio Mac", "Kitchen Mac"])
      #expect(readings.sources.map(\.isReporting) == [true, false, false])
    }

    @Test
    func fixtureTransportRefusesNetwork() async {
      let transport = FixtureBlockedHTTPTransport()
      await #expect(throws: HTTPTransportError.unavailable) {
        _ = try await transport.perform(
          URLRequest(url: URL(string: "https://quota.gotry.io/")!))
      }
    }

    @Test
    func relativeAgeRollsOverOnAnAdvancingClock() {
      let clock = AdvancingDisplayClock(VisualFixture.referenceDate)
      let model = AppModel.visualFixture(
        .content, now: { clock.now() }, clockIsFixed: true)
      let fetched = model.fetchedAt!
      let first = QuotaFormat.updated(fetched, now: clock.now())
      clock.advance(by: 120)
      let second = QuotaFormat.updated(fetched, now: clock.now())
      #expect(first != second)
      #expect(model.displayNow == clock.now())
    }
  }

  struct FixtureRouteParserTests {
    @Test
    func parseRecognizesDirectDestinations() {
      #expect(FixtureRoute.parse("usage.patterns") == .usagePatterns)
      #expect(FixtureRoute.parse("usage.day") == .usageDay)
      #expect(FixtureRoute.parse("usage.breakdown") == .usageBreakdown)
      #expect(FixtureRoute.parse("usage") == .usageRoot)
      #expect(FixtureRoute.parse("usage.today") == .usageToday)
      #expect(FixtureRoute.parse("usage.custom") == .usageCustom)
      #expect(FixtureRoute.parse("settings.devices") == .settingsDevices)
      #expect(FixtureRoute.parse("settings.notifications") == .settingsNotifications)
      #expect(
        FixtureRoute.parse("subscription.detail/codex|visual_codex|global|")
          == .subscriptionDetail("codex|visual_codex|global|"))
      #expect(FixtureRoute.parse(arguments: ["--route", "usage.patterns"]) == .usagePatterns)
      #expect(FixtureRoute.parse(arguments: ["Quota"]) == nil)
    }

    @Test
    func visualClockWallIsOptIn() {
      #expect(VisualClock.parse(arguments: ["--visual-clock", "wall"]) == .wall)
      #expect(VisualClock.parse(arguments: ["--visual-fixture", "content"]) == nil)
    }
  }

  final class AdvancingDisplayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) {
      self.instant = instant
    }

    func now() -> Date {
      lock.lock()
      defer { lock.unlock() }
      return instant
    }

    func advance(by interval: TimeInterval) {
      lock.lock()
      instant += interval
      lock.unlock()
    }
  }
#endif
