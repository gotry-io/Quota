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
      ("connecting", VisualFixture.connecting),
      ("connect-error", VisualFixture.connectError),
      ("expired", VisualFixture.expired),
      ("confirm-account", VisualFixture.confirmAccount),
      ("connect-refresh-failed", VisualFixture.connectRefreshFailed),
      ("loading", VisualFixture.loading),
      ("content", VisualFixture.content),
      ("cached-error", VisualFixture.cachedError),
      ("empty", VisualFixture.empty),
      ("no-devices", VisualFixture.noDevices),
      ("activity-loading", VisualFixture.activityLoading),
      ("activity-failed", VisualFixture.activityFailed),
      ("activity-day-empty", VisualFixture.activityDayEmpty),
      ("activity-day-failed", VisualFixture.activityDayFailed),
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
      #expect(model.activityChart == .idle)
    }

    @Test
    func connectingShowsDisabledProgressState() {
      let model = AppModel.visualFixture(.connecting, now: VisualFixture.referenceDate)
      #expect(model.skipsRestore)
      #expect(model.phase == .connecting)
      #expect(model.banner == nil)
      #expect(model.expiredMessage == nil)
    }

    @Test
    func connectErrorShowsTheGenericFailureLine() {
      let model = AppModel.visualFixture(.connectError, now: VisualFixture.referenceDate)
      #expect(model.skipsRestore)
      #expect(model.phase == .signedOut)
      #expect(model.banner?.text == "Couldn't connect. Try again.")
      #expect(model.expiredMessage == nil)
    }

    @Test
    func expiredShowsTheReconnectLine() {
      let model = AppModel.visualFixture(.expired, now: VisualFixture.referenceDate)
      #expect(model.skipsRestore)
      #expect(model.phase == .signedOut)
      #expect(model.banner == nil)
      #expect(model.expiredMessage == "Session expired. Connect again.")
    }

    @Test
    func loadingShowsLaunchingWithNoSurfaceState() {
      let model = AppModel.visualFixture(.loading, now: VisualFixture.referenceDate)
      #expect(model.skipsRestore)
      #expect(model.phase == .launching)
      #expect(model.summary == nil)
      #expect(model.banner == nil)
    }

    @Test
    func confirmAccountShowsTheConnectedGitHubLabel() {
      let model = AppModel.visualFixture(.confirmAccount, now: VisualFixture.referenceDate)
      #expect(model.skipsRestore)
      #expect(model.phase == .confirmingAccount(label: "octocat"))
      #expect(model.summary?.account.displayLabel == "octocat")
      #expect(model.banner == nil)
    }

    @Test
    func connectRefreshFailedShowsRetryCopyWithoutConfirmation() {
      let model = AppModel.visualFixture(
        .connectRefreshFailed, now: VisualFixture.referenceDate)
      #expect(model.skipsRestore)
      #expect(model.phase == .pendingRefreshFailed)
      #expect(model.banner?.text == "Could not reach quota.gotry.io.")
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

      let codex = try #require(
        model.summary?.subscriptions.first { $0.snapshot.provider == .codex })
      #expect(codex.sources.count == 2)
      #expect(model.summary?.devices.map(\.displayName) == ["Studio Mac", "Kitchen Mac"])
      let readings = SubscriptionDetailContent.make(
        subscription: codex,
        devices: model.summary?.devices ?? [],
        now: VisualFixture.referenceDate
      )
      #expect(readings.sources.map(\.displayName) == ["Studio Mac", "Kitchen Mac"])
      #expect(readings.sources.map(\.isReporting) == [true, false])

      let usage = model.summary!.usage
      let today = usage.today
      #expect(today.totals.inputTokens == 1_420_500)
      #expect(today.totals.outputTokens == 284_120)
      #expect(today.totals.messages == 164)
      #expect(today.cost.status == .complete)
      #expect(today.cost.amountMicrousd == "1489234")
      #expect(today.totals.totalTokens < usage.last7Days.totals.totalTokens)
      #expect(usage.last7Days.totals.totalTokens < usage.last30Days.totals.totalTokens)
      #expect(usage.last30Days.totals.totalTokens < usage.all.totals.totalTokens)

      let openaiModels =
        usage.last30Days.agents
        .first { $0.agent == .codex }?
        .providers.first { $0.provider == .openai }?
        .models ?? []
      #expect(openaiModels.count > 5)
      #expect(openaiModels.contains { $0.model == "other" })
      #expect(model.selectedUsagePeriod == .last30Days)

      guard case .loaded(let days) = model.activityChart else {
        Issue.record("content fixture should preload activity")
        return
      }
      #expect(!days.isEmpty)
      #expect(
        days.contains { $0.date == UsageActivityCalendar.utcDay(from: VisualFixture.referenceDate) }
      )

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
      #expect(model.banner?.text == AppModel.Banner.cachedText)
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
      #expect(model.summary?.usage.today.agents.isEmpty == true)
      #expect(model.summary?.usage.last30Days.agents.isEmpty == true)
      #expect(model.banner == nil)
      #expect(model.activityChart == .loaded([]))
    }

    @Test
    func activityLoadingKeepsPeriodTotalsAndShowsTheSkeletonPhase() {
      let model = AppModel.visualFixture(.activityLoading, now: VisualFixture.referenceDate)
      #expect(model.skipsRestore)
      #expect(model.phase == .signedIn)
      #expect(model.selectedTab == .usage)
      #expect(model.activityChart == .loading)
      #expect(model.summary?.usage.last30Days.agents.isEmpty == false)
      #expect(model.activityDaySheet == nil)
    }

    @Test
    func activityFailedKeepsPeriodTotalsAndShowsRetryPhase() {
      let model = AppModel.visualFixture(.activityFailed, now: VisualFixture.referenceDate)
      #expect(model.phase == .signedIn)
      #expect(model.selectedTab == .usage)
      #expect(model.activityChart == .failed)
      #expect(model.summary?.usage.last30Days.agents.isEmpty == false)
    }

    @Test
    func activityDayEmptyPresentsASheetWithNoAgents() {
      let model = AppModel.visualFixture(.activityDayEmpty, now: VisualFixture.referenceDate)
      #expect(model.selectedTab == .usage)
      #expect(model.activityDaySheet?.agents == .empty)
      #expect(model.activityDaySheet?.headline.agents == nil)
      #expect(model.activityDaySheet?.headline.totals.totalTokens == 0)
    }

    @Test
    func activityDayFailedPresentsASheetWithRetryPhase() {
      let model = AppModel.visualFixture(.activityDayFailed, now: VisualFixture.referenceDate)
      #expect(model.selectedTab == .usage)
      #expect(model.activityDaySheet?.agents == .failed)
      #expect(model.activityDaySheet?.date == "2026-08-14")
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
