#if DEBUG
  import Foundation
  import QuotaPresentation
  import QuotaWire
  import Testing

  @testable import QuotaBar

  @MainActor
  struct DashboardModelTests {
    @Test
    func providerOrderFollowsOverview() throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let referenceDate = Date(timeIntervalSince1970: 1_785_752_430)
      let configuration = try #require(
        VisualTestConfiguration(
          arguments: ["QuotaBar", "--fixture", "content", "--route", "main-quota"],
          referenceDate: referenceDate
        )
      )
      configuration.prepareEnvironment()
      let model = configuration.makeModel()
      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      #expect(dashboard.sidebarProviders == [.codex, .claude, .grok])
      #expect(
        dashboard.providers(now: referenceDate).map(\.provider) == [.codex, .claude, .grok]
      )
    }

    @Test
    func pacePhraseEqualsThePanelForTheSameReading() throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let referenceDate = Date(timeIntervalSince1970: 1_785_752_430)
      let configuration = try #require(
        VisualTestConfiguration(
          arguments: ["QuotaBar", "--fixture", "content", "--route", "main-quota"],
          referenceDate: referenceDate
        )
      )
      configuration.prepareEnvironment()
      let model = configuration.makeModel()
      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      for provider in dashboard.providers(now: referenceDate) {
        let snapshot = try #require(model.displaySnapshots(for: provider.provider).first?.snapshot)
        let window = try #require(snapshot.primaryCadenceWindows.first ?? snapshot.windows.first)
        let expected = window.pace.flatMap { QuotaPaceCopy.line($0, resetsAt: window.resetsAt) }
        #expect(provider.pacePhrase == expected)
      }
    }

    @Test
    func remainingPercentIsThePrimaryWindow() throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let referenceDate = Date(timeIntervalSince1970: 1_785_752_430)
      let configuration = try #require(
        VisualTestConfiguration(
          arguments: ["QuotaBar", "--fixture", "content", "--route", "main-quota"],
          referenceDate: referenceDate
        )
      )
      configuration.prepareEnvironment()
      let model = configuration.makeModel()
      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      for provider in dashboard.providers(now: referenceDate) {
        let snapshot = try #require(model.displaySnapshots(for: provider.provider).first?.snapshot)
        let window = try #require(snapshot.primaryCadenceWindows.first ?? snapshot.windows.first)
        #expect(provider.remainingPercent == window.remainingPercent)
      }
    }

    @Test
    func selectionNarrowsToOneProvider() throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let referenceDate = Date(timeIntervalSince1970: 1_785_752_430)
      let configuration = try #require(
        VisualTestConfiguration(
          arguments: ["QuotaBar", "--fixture", "content", "--route", "main-quota"],
          referenceDate: referenceDate
        )
      )
      configuration.prepareEnvironment()
      let model = configuration.makeModel()
      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      #expect(dashboard.displayedProviders(now: referenceDate).count == 3)
      dashboard.selection = .codex
      let displayed = dashboard.displayedProviders(now: referenceDate)
      #expect(displayed.map(\.provider) == [.codex])
    }

    @Test
    func todayRowsNameEachWindowThatHadSamplesToday() throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let referenceDate = Date(timeIntervalSince1970: 1_785_752_430)
      let configuration = try #require(
        VisualTestConfiguration(
          arguments: ["QuotaBar", "--fixture", "content", "--route", "main-quota"],
          referenceDate: referenceDate
        )
      )
      configuration.prepareEnvironment()
      let model = configuration.makeModel()
      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      let rows = dashboard.todayRows(now: referenceDate)
      #expect(!rows.isEmpty)
      #expect(Set(rows.map(\.provider)).isSuperset(of: [.codex, .claude, .grok]))
      for row in rows {
        #expect(row.usedLine.contains("→"))
        #expect(!row.windowName.isEmpty)
        #expect(!row.resetText.isEmpty)
      }
      dashboard.selection = .codex
      let codexRows = dashboard.todayRows(now: referenceDate)
      #expect(!codexRows.isEmpty)
      #expect(codexRows.allSatisfy { $0.provider == .codex })
    }

    @Test
    func projectsTableIsAbsentForTheAccountSourceAndPresentOnThisMac() throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let referenceDate = Date(timeIntervalSince1970: 1_785_752_430)
      let configuration = try #require(
        VisualTestConfiguration(
          arguments: ["QuotaBar", "--fixture", "content", "--route", "main-usage"],
          referenceDate: referenceDate
        )
      )
      configuration.prepareEnvironment()
      let model = configuration.makeModel()
      let dashboard = DashboardModel(
        model: model, defaults: defaults.store, usageSource: .account)
      #expect(dashboard.presentedUsageSource == .account)
      #expect(!dashboard.showsUsageProjects)
      let account = dashboard.presentedUsage(now: referenceDate)
      #expect(account.usage?.projects == nil)
      #expect(!account.showsProjects)

      dashboard.usageSource = .local
      #expect(dashboard.showsUsageProjects)
      let local = dashboard.presentedUsage(now: referenceDate)
      #expect(local.usage?.projects?.map(\.projectKey) == ["Quota", "other"])
      #expect(local.showsProjects)
    }

    @Test
    func aCustomRangeLeavesThePeriodControlUnselected() throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let referenceDate = Date(timeIntervalSince1970: 1_785_752_430)
      let configuration = try #require(
        VisualTestConfiguration(
          arguments: ["QuotaBar", "--fixture", "content", "--route", "main-quota"],
          referenceDate: referenceDate
        )
      )
      configuration.prepareEnvironment()
      let model = configuration.makeModel()
      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      #expect(dashboard.selectedUsagePeriodSegment == .day)
      dashboard.selectUsagePeriod(.custom(from: "2026-08-01", to: "2026-08-03"))
      #expect(dashboard.selectedUsagePeriodSegment == nil)
      #expect(model.usagePeriod.segment == .custom)
      dashboard.selectUsagePeriod(.last7Days)
      #expect(dashboard.selectedUsagePeriodSegment == .last7Days)
    }

    @Test
    func rangeFilterCutsSamples() async throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let now = Date(timeIntervalSince1970: 1_788_100_000)
      let reset = now.addingTimeInterval(2 * 3_600)
      let snapshot = QuotaSnapshot(
        provider: .codex,
        account: QuotaAccount(
          fingerprint: "account_test",
          label: nil,
          plan: "Plus",
          fingerprintScope: .global
        ),
        windows: [
          QuotaWindow(
            id: "five_hour",
            title: "5 Hours",
            usedPercent: 40,
            resetsAt: reset,
            durationSeconds: 18_000,
            pace: QuotaPace.evaluate(
              QuotaPaceReading(
                usedPercent: 40,
                resetsAt: reset,
                cadenceSeconds: 18_000,
                isBalanceOnly: false
              ),
              now: now
            )
          )
        ],
        status: .available,
        observedAt: now
      )
      let source = LocalServiceOverviewSource(
        sourceID: "local",
        kind: .local,
        deviceID: nil,
        displayName: "This Mac",
        observedAt: now,
        isStale: false
      )
      let state = overviewOnlyState(
        overview: [
          LocalServiceOverviewItem(
            identity: LocalServiceOverviewIdentity(
              provider: .codex,
              fingerprint: "account_test",
              scope: .global,
              sourceID: nil
            ),
            snapshot: snapshot,
            sources: [source],
            selectedSourceID: source.sourceID,
            selectedSourceDisplayName: source.displayName,
            automaticSourceID: source.sourceID,
            automaticSourceDisplayName: source.displayName,
            isStale: false
          )
        ]
      )
      let samples = LocalServiceQuotaHistory(
        samplesBySubscription: [
          "ccfc96629357": [
            "five_hour": [
              QuotaSample(
                resetsAt: reset, observedAt: now.addingTimeInterval(-10 * 86_400), usedPercent: 10),
              QuotaSample(
                resetsAt: reset, observedAt: now.addingTimeInterval(-3 * 86_400), usedPercent: 20),
              QuotaSample(
                resetsAt: reset, observedAt: now.addingTimeInterval(-60), usedPercent: 40),
            ]
          ]
        ],
        utcOffsetSeconds: 0
      )
      let model = MenuBarViewModel(
        client: StubLocalService(state: state, quotaHistoryValue: samples)
      )
      await model.refreshIfNeeded()
      model.loadQuotaHistory()
      let deadline = ContinuousClock.now + .seconds(10)
      while model.quotaHistory.isEmpty, ContinuousClock.now < deadline {
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
      }

      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      dashboard.range = .today
      let todayCount = sampleCount(dashboard.providers(now: now), provider: .codex)
      dashboard.range = .sevenDays
      let weekCount = sampleCount(dashboard.providers(now: now), provider: .codex)
      dashboard.range = .thirtyDays
      let monthCount = sampleCount(dashboard.providers(now: now), provider: .codex)
      #expect(todayCount == 1)
      #expect(weekCount == 2)
      #expect(monthCount == 3)
    }

    @Test
    func twoAccountsOfOneProviderEachHaveTheirOwnChart() async throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let now = Date(timeIntervalSince1970: 1_788_100_000)
      let reset = now.addingTimeInterval(2 * 3_600)
      func item(fingerprint: String, used: Double) -> LocalServiceOverviewItem {
        let snapshot = QuotaSnapshot(
          provider: .codex,
          account: QuotaAccount(
            fingerprint: fingerprint,
            label: fingerprint,
            plan: "Plus",
            fingerprintScope: .global
          ),
          windows: [
            QuotaWindow(
              id: "five_hour",
              title: "5 Hours",
              usedPercent: used,
              resetsAt: reset,
              durationSeconds: 18_000
            )
          ],
          status: .available,
          observedAt: now
        )
        let source = LocalServiceOverviewSource(
          sourceID: "local",
          kind: .local,
          deviceID: nil,
          displayName: "This Mac",
          observedAt: now,
          isStale: false
        )
        return LocalServiceOverviewItem(
          identity: LocalServiceOverviewIdentity(
            provider: .codex,
            fingerprint: fingerprint,
            scope: .global,
            sourceID: nil
          ),
          snapshot: snapshot,
          sources: [source],
          selectedSourceID: source.sourceID,
          selectedSourceDisplayName: source.displayName,
          automaticSourceID: source.sourceID,
          automaticSourceDisplayName: source.displayName,
          isStale: false
        )
      }
      let first = item(fingerprint: "account_a", used: 20)
      let second = item(fingerprint: "account_b", used: 80)
      let firstKey = first.identity.subscriptionSelector
      let secondKey = second.identity.subscriptionSelector
      let samples = LocalServiceQuotaHistory(
        samplesBySubscription: [
          firstKey: [
            "five_hour": [
              QuotaSample(resetsAt: reset, observedAt: now, usedPercent: 20)
            ]
          ],
          secondKey: [
            "five_hour": [
              QuotaSample(resetsAt: reset, observedAt: now, usedPercent: 80)
            ]
          ],
        ],
        utcOffsetSeconds: 0
      )
      let model = MenuBarViewModel(
        client: StubLocalService(
          state: overviewOnlyState(overview: [first, second]),
          quotaHistoryValue: samples
        )
      )
      await model.refreshIfNeeded()
      model.loadQuotaHistory()
      let deadline = ContinuousClock.now + .seconds(10)
      while model.quotaHistory.isEmpty, ContinuousClock.now < deadline {
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
      }

      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      dashboard.selection = .codex
      let cards = dashboard.displayedProviders(now: now)
      #expect(cards.map(\.provider) == [.codex, .codex])
      #expect(Set(cards.map(\.id)) == [firstKey, secondKey])
      #expect(cards.map { $0.series.flatMap(\.points).map(\.usedPercent) } == [[20], [80]])
    }

    private func sampleCount(_ providers: [DashboardProvider], provider: ProviderID) -> Int {
      providers.first { $0.provider == provider }?.series.flatMap(\.points).count ?? 0
    }
  }

  private struct DashboardDefaultsSuite {
    let name: String
    let store: UserDefaults

    func tearDown() {
      store.removePersistentDomain(forName: name)
    }
  }

  private func dashboardDefaults() -> DashboardDefaultsSuite {
    let name = "QuotaBarTests.Dashboard.\(UUID().uuidString)"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    return DashboardDefaultsSuite(name: name, store: store)
  }
#endif

@Suite
@MainActor
struct DashboardProjectionTests {
  @Test
  func aProjectionPastFullEndsWhereTheLineCrossesFull() {
    let last = DashboardQuotaPoint(
      date: Date(timeIntervalSince1970: 0), usedPercent: 50, resetsAt: nil)
    let reset = Date(timeIntervalSince1970: 1_000)
    let point = DashboardModel.projectionPoint(
      from: last, toReset: reset, projectedUsedPercent: 150)
    #expect(point.usedPercent == 100)
    #expect(point.date == Date(timeIntervalSince1970: 500))
  }

  @Test
  func aProjectionWithinFullEndsAtTheReset() {
    let last = DashboardQuotaPoint(
      date: Date(timeIntervalSince1970: 0), usedPercent: 50, resetsAt: nil)
    let reset = Date(timeIntervalSince1970: 1_000)
    let point = DashboardModel.projectionPoint(
      from: last, toReset: reset, projectedUsedPercent: 80)
    #expect(point.usedPercent == 80)
    #expect(point.date == reset)
  }
}
