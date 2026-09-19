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
        dashboard.subscriptions(now: referenceDate).map(\.provider) == [.codex, .claude, .grok]
      )
    }

    @Test
    func paceHeadlineEqualsThePanelForTheSameReading() throws {
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
      for provider in dashboard.subscriptions(now: referenceDate) {
        let snapshot = try #require(model.displaySnapshots(for: provider.provider).first?.snapshot)
        let window = try #require(snapshot.primaryCadenceWindows.first ?? snapshot.windows.first)
        let expectedHeadline = window.pace.flatMap {
          QuotaPaceCopy.headline($0, resetsAt: window.resetsAt)
        }
        #expect(provider.paceHeadline == expectedHeadline)
        #expect(provider.paceDetail == window.pace.flatMap { QuotaPaceCopy.detail($0) })
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
      for provider in dashboard.subscriptions(now: referenceDate) {
        let snapshot = try #require(model.displaySnapshots(for: provider.provider).first?.snapshot)
        let window = try #require(snapshot.primaryCadenceWindows.first ?? snapshot.windows.first)
        #expect(provider.remainingPercent == window.remainingPercent)
      }
    }

    @Test
    func listRowSpeaksProviderAccountAndRemainingOnce() throws {
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
      let codex = try #require(
        dashboard.subscriptions(now: referenceDate).first { $0.provider == .codex }
      )
      let label = codex.rowAccessibilityLabel
      #expect(label.contains(ProviderID.codex.displayName))
      if let account = codex.accountLabel {
        #expect(label.contains(account))
      }
      if let remaining = codex.remainingPercent {
        #expect(label.contains(RemainingQuotaFormat.percent(remaining)))
      }
      #expect(!label.contains("remaining remaining"))
      let providerCount = label.components(separatedBy: ProviderID.codex.displayName).count - 1
      #expect(providerCount == 1)
    }

    @Test
    func selectionPersistsForTheSessionAndFallsBackWhenGone() throws {
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
      let items = dashboard.subscriptions(now: referenceDate)
      #expect(items.count == 3)
      let first = try #require(items.first)
      let second = try #require(items.dropFirst().first)
      #expect(dashboard.resolvedSubscriptionID(now: referenceDate) == first.id)
      dashboard.selectSubscription(second.id)
      #expect(dashboard.resolvedSubscriptionID(now: referenceDate) == second.id)
      #expect(dashboard.selectedSubscription(now: referenceDate)?.id == second.id)
      dashboard.selectSubscription("missing-subscription")
      #expect(dashboard.resolvedSubscriptionID(now: referenceDate) == first.id)
    }

    @Test
    func preferredProviderSelectsThatProvidersFirstSubscription() throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let referenceDate = Date(timeIntervalSince1970: 1_785_752_430)
      let configuration = try #require(
        VisualTestConfiguration(
          arguments: ["QuotaBar", "--fixture", "content", "--route", "main-quota-codex"],
          referenceDate: referenceDate
        )
      )
      configuration.prepareEnvironment()
      let model = configuration.makeModel()
      let dashboard = DashboardModel(
        model: model, defaults: defaults.store, selection: configuration.quotaSelection)
      let selected = try #require(dashboard.selectedSubscription(now: referenceDate))
      #expect(selected.provider == .codex)
      #expect(dashboard.subscriptions(now: referenceDate).count == 3)
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
      dashboard.selectSubscription(
        try #require(dashboard.subscriptions(now: referenceDate).first { $0.provider == .codex }?.id)
      )
      let afterSelection = dashboard.todayRows(now: referenceDate)
      #expect(Set(afterSelection.map(\.provider)).isSuperset(of: [.codex, .claude, .grok]))
    }

    @Test
    func todayWindowsTableBelongsToTheTodayUsagePeriod() throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let referenceDate = Date(timeIntervalSince1970: 1_785_752_430)
      let configuration = try #require(
        VisualTestConfiguration(
          arguments: ["QuotaBar", "--fixture", "content", "--route", "main-today"],
          referenceDate: referenceDate
        )
      )
      configuration.prepareEnvironment()
      let model = configuration.makeModel()
      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      #expect(dashboard.usagePeriod == .today)
      #expect(dashboard.showsTodayWindows)
      #expect(!dashboard.todayRows(now: referenceDate).isEmpty)
      dashboard.selectUsagePeriod(.last7Days)
      #expect(!dashboard.showsTodayWindows)
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
      #expect(model.usage.usagePeriod.segment == .custom)
      dashboard.selectUsagePeriod(.last7Days)
      #expect(dashboard.selectedUsagePeriodSegment == .last7Days)
    }

    @Test
    func localCodexReadingCarriesRemainingHistoryWhoseEstimateMatchesPace() throws {
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
      let codex = try #require(
        dashboard.subscriptions(now: referenceDate).first { $0.provider == .codex }
      )
      #expect(codex.isLocalReading)
      #expect(codex.plan != nil)
      let window = try #require(codex.quotaWindows.first)
      let samples =
        model.usage.quotaHistorySamples?.samplesBySubscription[codex.id]?[window.id] ?? []
      let folded = try #require(
        QuotaRemainingHistory.fold(
          window: QuotaHistoryReading(
            resetsAt: window.resetsAt, cadenceSeconds: window.durationSeconds),
          samples: samples,
          usedPercent: window.usedPercent,
          now: referenceDate,
          isBalanceOnly: window.isBalanceOnly
        )
      )
      #expect(codex.remainingHistories[window.id] == folded)
      #expect(!folded.observedPoints.isEmpty)
      #expect(!codex.sources.isEmpty)
      #expect(codex.sources.contains { $0.isLocal && $0.isReporting })
    }

    @Test
    func remoteOnlySubscriptionHasNoRemainingHistory() throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let now = Date(timeIntervalSince1970: 1_788_100_000)
      let reset = now.addingTimeInterval(2 * 3_600)
      let snapshot = QuotaSnapshot(
        provider: .codex,
        account: QuotaAccount(
          fingerprint: "account_remote",
          label: "remote-user",
          plan: "Plus",
          fingerprintScope: .global
        ),
        windows: [
          QuotaWindow(
            id: "five_hour",
            title: "5 Hours",
            usedPercent: 40,
            resetsAt: reset,
            durationSeconds: 18_000
          )
        ],
        status: .available,
        observedAt: now
      )
      let source = LocalServiceOverviewSource(
        sourceID: "device:other",
        kind: .device,
        deviceID: "other",
        displayName: "Studio Mac",
        observedAt: now,
        isStale: false,
        snapshot: snapshot
      )
      let item = LocalServiceOverviewItem(
        identity: LocalServiceOverviewIdentity(
          provider: .codex,
          fingerprint: "account_remote",
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
      let state = overviewOnlyState(overview: [item])
      let model = MenuBarViewModel(client: StubLocalService(state: state))
      model.apply(state)
      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      let subscription = try #require(dashboard.subscriptions(now: now).first)
      #expect(!subscription.isLocalReading)
      #expect(subscription.remainingHistories.isEmpty)
      #expect(subscription.sources.map(\.displayName) == ["Studio Mac"])
      #expect(subscription.rowAccessibilityLabel.contains(ProviderID.codex.displayName))
    }

    @Test
    func twoAccountsOfOneProviderEachHaveTheirOwnRow() async throws {
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
          isStale: false,
          snapshot: snapshot
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
      let state = overviewOnlyState(overview: [first, second])
      let model = MenuBarViewModel(
        client: StubLocalService(state: state, quotaHistoryValue: samples)
      )
      model.apply(state)
      model.usage.loadQuotaHistory()
      let deadline = ContinuousClock.now + .seconds(10)
      while model.usage.quotaHistory.isEmpty, ContinuousClock.now < deadline {
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
      }

      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      let rows = dashboard.subscriptions(now: now)
      #expect(rows.map(\.provider) == [.codex, .codex])
      #expect(Set(rows.map(\.id)) == [firstKey, secondKey])
      #expect(Set(rows.map(\.accountLabel)) == ["account_a", "account_b"])
      #expect(rows.allSatisfy { $0.isLocalReading })
      #expect(
        rows.map { $0.remainingHistories["five_hour"]?.observedPoints.last?.remainingPercent }
          == [80, 20]
      )
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
