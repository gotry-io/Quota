import Foundation
import QuotaWire
import Testing

@testable import Quota

struct VisualFixtureParserTests {
  @Test
  func parseReturnsNilWhenFlagAbsent() {
    #expect(VisualFixture.parse(arguments: ["Quota"]) == nil)
    #expect(VisualFixture.parse(arguments: []) == nil)
  }

  @Test
  func parseReturnsNilWhenValueMissingOrUnknown() {
    #expect(VisualFixture.parse(arguments: ["--visual-fixture"]) == nil)
    #expect(VisualFixture.parse(arguments: ["--visual-fixture", "unknown"]) == nil)
    #expect(VisualFixture.parse(arguments: ["--visual-fixture", "signed_out"]) == nil)
  }

  @Test(
    arguments: [
      ("signed-out", VisualFixture.signedOut),
      ("content", VisualFixture.content),
      ("cached-error", VisualFixture.cachedError),
      ("empty", VisualFixture.empty),
      ("no-devices", VisualFixture.noDevices),
    ]
  )
  func parseRecognizesEachFixture(raw: String, expected: VisualFixture) {
    #expect(VisualFixture.parse(arguments: ["Quota", "--visual-fixture", raw]) == expected)
  }
}

#if DEBUG
  @MainActor
  struct VisualFixtureStateTests {
    @Test
    func signedOutSkipsRestoreAndShowsConnect() {
      let model = AppModel.visualFixture(.signedOut, now: VisualFixture.referenceDate)
      #expect(model.skipsRestore)
      #expect(model.phase == .signedOut)
      #expect(model.summary == nil)
      #expect(model.banner == nil)
      #expect(model.expiredMessage == nil)
    }

    @Test
    func contentIncludesCodexClaudeGrokAndTodayValues() throws {
      let model = AppModel.visualFixture(.content, now: VisualFixture.referenceDate)
      #expect(model.skipsRestore)
      #expect(model.phase == .signedIn)
      #expect(model.accountLabel == "octocat")
      #expect(model.fromCache == false)
      #expect(model.banner == nil)

      let providers = Set(model.providerCards.map(\.provider))
      #expect(providers == [.codex, .claude, .grok])
      #expect(model.providerCards.count == 3)

      let codex = try #require(model.summary?.subscriptions.first { $0.snapshot.provider == .codex })
      #expect(codex.sources.count == 2)
      #expect(model.summary?.devices.map(\.displayName) == ["Studio Mac", "Kitchen Mac"])
      let readings = SubscriptionDetailContent.make(
        subscription: codex,
        devices: model.summary?.devices ?? [],
        now: VisualFixture.referenceDate
      )
      #expect(readings.sources.map(\.displayName) == ["Studio Mac", "Kitchen Mac"])
      #expect(readings.sources.map(\.isReporting) == [true, false])

      let usage = model.summary?.usage.today
      #expect(usage?.totals.inputTokens == 1_420_500)
      #expect(usage?.totals.outputTokens == 284_120)
      #expect(usage?.totals.messages == 164)
      #expect(usage?.cost.status == .complete)
      #expect(usage?.cost.amountMicrousd == "1489234")

      // Fixtures must never carry session material.
      #expect(model.summary?.account.accountID.hasPrefix("account_visual_") == true)
    }

    @Test
    func factoryDerivesFetchedAndResetDatesRelativeToInjectedNow() {
      // Distinct from referenceDate so relative offsets are proven, not coincidental.
      let now = Date(timeIntervalSince1970: 1_800_000_000)
      let model = AppModel.visualFixture(.content, now: now)

      #expect(model.fetchedAt == now.addingTimeInterval(-90))
      #expect(model.summary?.account.createdAt == now.addingTimeInterval(-30 * 86_400))

      let codex = model.summary?.subscriptions.first { $0.snapshot.provider == .codex }
      #expect(codex?.snapshot.observedAt == now.addingTimeInterval(-90))
      let fiveHour = codex?.snapshot.windows.first { $0.id == "five_hour" }
      #expect(fiveHour?.resetsAt == now.addingTimeInterval(2_700))
      let weekly = codex?.snapshot.windows.first { $0.id == "weekly" }
      #expect(weekly?.resetsAt == now.addingTimeInterval(4 * 86_400))

      let claude = model.summary?.subscriptions.first { $0.snapshot.provider == .claude }
      let session = claude?.snapshot.windows.first { $0.id == "five_hour" }
      #expect(session?.resetsAt == now.addingTimeInterval(7_200))

      let grok = model.summary?.subscriptions.first { $0.snapshot.provider == .grok }
      let monthly = grok?.snapshot.windows.first { $0.id == "monthly" }
      #expect(monthly?.resetsAt == now.addingTimeInterval(12 * 86_400))

      let cached = AppModel.visualFixture(.cachedError, now: now)
      #expect(cached.fetchedAt == now.addingTimeInterval(-180))

      let empty = AppModel.visualFixture(.empty, now: now)
      #expect(empty.fetchedAt == now.addingTimeInterval(-60))
    }

    @Test
    func cachedErrorKeepsContentAndShowsSavedBanner() {
      let model = AppModel.visualFixture(.cachedError, now: VisualFixture.referenceDate)
      #expect(model.skipsRestore)
      #expect(model.phase == .signedIn)
      #expect(model.fromCache)
      #expect(model.summary != nil)
      #expect(model.banner?.kind == .offlineCached)
      #expect(model.banner?.text == "Showing saved account data. Could not refresh.")
      #expect(model.providerCards.map(\.provider) == [.codex, .claude, .grok])
    }

    @Test
    func emptyShowsSignedInWithNoQuotaOrTodayUsage() {
      let model = AppModel.visualFixture(.empty, now: VisualFixture.referenceDate)
      #expect(model.skipsRestore)
      #expect(model.phase == .signedIn)
      #expect(model.providerCards.isEmpty)
      #expect(model.summary?.subscriptions.isEmpty == true)
      #expect(model.summary?.usage.today.totals.messages == 0)
      #expect(model.summary?.usage.today.totals.inputTokens == 0)
      #expect(model.banner == nil)
    }

    @Test
    func noDevicesIsSignedInWithoutDevicesOrSubscriptions() {
      let model = AppModel.visualFixture(.noDevices, now: VisualFixture.referenceDate)
      #expect(model.skipsRestore)
      #expect(model.phase == .signedIn)
      #expect(model.summary?.devices.isEmpty == true)
      #expect(model.summary?.subscriptions.isEmpty == true)
      #expect(model.providerCards.isEmpty)
      #expect(model.banner == nil)
    }
  }
#endif
