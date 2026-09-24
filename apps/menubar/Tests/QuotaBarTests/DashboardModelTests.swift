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

    /// The row's percent and its pace line both come from the primary window the panel shows,
    /// not from whichever window happens to be first or tightest.
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
        #expect(
          provider.paceHeadline
            == window.pace.flatMap { QuotaPaceCopy.headline($0, resetsAt: window.resetsAt) })
      }
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
      #expect(subscription.historyCaption == nil)
      #expect(subscription.historySource == nil)
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
      try await waitUntil { !model.usage.quotaHistory.isEmpty }

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

    @Test
    func accountHistoryReplacesTheLocalSeriesWhileTheSwitchIsOn() async throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let now = Date(timeIntervalSince1970: 1_788_100_000)
      let reset = now.addingTimeInterval(2 * 3_600)
      let item = historySubscription(fingerprint: "account_hist", used: 20, now: now, reset: reset)
      let key = item.identity.subscriptionSelector
      let local = historyPayload(key: key, reset: reset, observedAt: now, used: 20)
      let account = historyPayload(key: key, reset: reset, observedAt: now, used: 70)
      let script = QuotaHistoryAccountScript([.success(account)])
      let state = signedInSettingsState(
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 1),
          revision: 1
        ),
        overview: [item]
      )
      let model = MenuBarViewModel(
        client: StubLocalService(
          state: state, quotaHistoryValue: local, accountQuotaHistory: script)
      )
      model.apply(state)
      model.usage.loadQuotaHistory()
      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      try await waitUntil {
        dashboard.subscriptions(now: now).first?.remainingHistories["five_hour"] != nil
      }
      let before = try #require(dashboard.subscriptions(now: now).first)
      #expect(before.historySource == .thisDevice)
      let localFold = try #require(foldedHistory(samples: local, key: key, item: item, now: now))
      #expect(before.remainingHistories["five_hour"] == localFold)

      model.setHistorySync(true)
      let epoch = model.usage.accountHistoryEpoch
      dashboard.loadAccountHistory(now: now)
      try await waitUntil { model.usage.accountHistoryEpoch > epoch }
      let after = try #require(dashboard.subscriptions(now: now).first)
      #expect(after.historyCaption == "From your devices")
      #expect(after.historySource == .yourDevices)
      #expect(after.drawsAccountHistory)
      let buckets = (account.samplesBySubscription[key]?["five_hour"] ?? []).map { sample in
        QuotaHistorySync.Bucket(
          resetsAt: sample.resetsAt, bucketStart: sample.observedAt, usedPercent: sample.usedPercent)
      }
      let accountFold = try #require(
        QuotaRemainingHistory.fold(
          window: QuotaHistoryReading(resetsAt: reset, cadenceSeconds: 18_000),
          samples: QuotaHistorySync.samples(from: buckets),
          usedPercent: 20,
          now: now
        )
      )
      #expect(after.remainingHistories["five_hour"] == accountFold)
      #expect(after.remainingHistories["five_hour"] != localFold)
    }

    @Test
    func accountSeriesAppendsTheCurrentReadingAtNow() async throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let now = Date(timeIntervalSince1970: 1_788_100_000)
      let reset = now.addingTimeInterval(2 * 3_600)
      let lastChange = now.addingTimeInterval(-2 * 3_600)
      let item = historySubscription(fingerprint: "account_hist", used: 80, now: now, reset: reset)
      let key = item.identity.subscriptionSelector
      let local = historyPayload(key: key, reset: reset, observedAt: now, used: 80)
      let account = historyPayload(key: key, reset: reset, observedAt: lastChange, used: 40)
      let script = QuotaHistoryAccountScript([.success(account)])
      let state = signedInSettingsState(
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 1),
          revision: 1
        ),
        overview: [item]
      )
      let model = MenuBarViewModel(
        client: StubLocalService(
          state: state, quotaHistoryValue: local, accountQuotaHistory: script)
      )
      model.apply(state)
      model.setHistorySync(true)
      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      let epoch = model.usage.accountHistoryEpoch
      dashboard.loadAccountHistory(now: now)
      try await waitUntil { model.usage.accountHistoryEpoch > epoch }
      let history = try #require(
        dashboard.subscriptions(now: now).first?.remainingHistories["five_hour"]
      )
      let last = try #require(history.observedPoints.last)
      #expect(last.date == now)
      #expect(last.remainingPercent == RemainingQuotaFormat.remainingPercent(usedPercent: 80))
      #expect(history.observedPoints.contains { $0.date == lastChange })
    }

    @Test
    func aFailedAccountReadWithNothingCachedKeepsThisMac() async throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let now = Date(timeIntervalSince1970: 1_788_100_000)
      let reset = now.addingTimeInterval(2 * 3_600)
      let item = historySubscription(fingerprint: "account_hist", used: 20, now: now, reset: reset)
      let key = item.identity.subscriptionSelector
      let local = historyPayload(key: key, reset: reset, observedAt: now, used: 20)
      let script = QuotaHistoryAccountScript([
        .failure(LocalServiceClientError.connectionClosed)
      ])
      let state = signedInSettingsState(
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 1),
          revision: 1
        ),
        overview: [item]
      )
      let model = MenuBarViewModel(
        client: StubLocalService(
          state: state, quotaHistoryValue: local, accountQuotaHistory: script)
      )
      model.apply(state)
      model.usage.loadQuotaHistory()
      model.setHistorySync(true)
      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      try await waitUntil { model.usage.quotaHistorySamples != nil }
      let epoch = model.usage.accountHistoryEpoch
      dashboard.loadAccountHistory(now: now)
      try await waitUntil { model.usage.accountHistoryEpoch > epoch }
      let subscription = try #require(dashboard.subscriptions(now: now).first)
      #expect(subscription.historyCaption == "This Mac")
      #expect(subscription.historySource == .thisDevice)
      #expect(!subscription.drawsAccountHistory)
      #expect(
        subscription.remainingHistories["five_hour"]
          == foldedHistory(samples: local, key: key, item: item, now: now)
      )
    }

    @Test
    func aFailedAccountReadKeepsTheCachedAccountSeries() async throws {
      let defaults = dashboardDefaults()
      defer { defaults.tearDown() }
      let now = Date(timeIntervalSince1970: 1_788_100_000)
      let reset = now.addingTimeInterval(2 * 3_600)
      let item = historySubscription(fingerprint: "account_hist", used: 20, now: now, reset: reset)
      let key = item.identity.subscriptionSelector
      let local = historyPayload(key: key, reset: reset, observedAt: now, used: 20)
      let account = historyPayload(key: key, reset: reset, observedAt: now, used: 70)
      let script = QuotaHistoryAccountScript([
        .success(account),
        .failure(LocalServiceClientError.connectionClosed),
      ])
      let state = signedInSettingsState(
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 1),
          revision: 1
        ),
        overview: [item]
      )
      let model = MenuBarViewModel(
        client: StubLocalService(
          state: state, quotaHistoryValue: local, accountQuotaHistory: script)
      )
      model.apply(state)
      model.setHistorySync(true)
      let dashboard = DashboardModel(model: model, defaults: defaults.store)
      let first = model.usage.accountHistoryEpoch
      dashboard.loadAccountHistory(now: now)
      try await waitUntil { model.usage.accountHistoryEpoch > first }
      #expect(dashboard.subscriptions(now: now).first?.historyCaption == "From your devices")
      let cached = dashboard.subscriptions(now: now).first?.remainingHistories["five_hour"]

      let second = model.usage.accountHistoryEpoch
      dashboard.loadAccountHistory(now: now)
      try await waitUntil { model.usage.accountHistoryEpoch > second }
      let subscription = try #require(dashboard.subscriptions(now: now).first)
      #expect(subscription.historyCaption == "From your devices")
      #expect(subscription.remainingHistories["five_hour"] == cached)
      #expect(subscription.drawsAccountHistory)
    }
  }

  private struct DashboardDefaultsSuite {
    let name: String
    let store: UserDefaults

    func tearDown() {
      store.removePersistentDomain(forName: name)
    }
  }

  private func historySubscription(
    fingerprint: String, used: Double, now: Date, reset: Date
  ) -> LocalServiceOverviewItem {
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

  private func historyPayload(
    key: String, reset: Date, observedAt: Date, used: Double
  ) -> LocalServiceQuotaHistory {
    LocalServiceQuotaHistory(
      samplesBySubscription: [
        key: [
          "five_hour": [
            QuotaSample(resetsAt: reset, observedAt: observedAt, usedPercent: used)
          ]
        ]
      ],
      utcOffsetSeconds: 0
    )
  }

  private func foldedHistory(
    samples: LocalServiceQuotaHistory,
    key: String,
    item: LocalServiceOverviewItem,
    now: Date
  ) -> QuotaRemainingHistory? {
    guard let window = item.snapshot.windows.first else { return nil }
    return QuotaRemainingHistory.fold(
      window: QuotaHistoryReading(
        resetsAt: window.resetsAt, cadenceSeconds: window.durationSeconds),
      samples: samples.samplesBySubscription[key]?[window.id] ?? [],
      usedPercent: window.usedPercent,
      now: now
    )
  }

  @MainActor
  private func waitUntil(
    _ condition: @escaping @MainActor () async -> Bool,
    seconds: Double = 5
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while await !condition() {
      if ContinuousClock.now >= deadline {
        Issue.record("timed out waiting for condition")
        return
      }
      await Task.yield()
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func dashboardDefaults() -> DashboardDefaultsSuite {
    let name = "QuotaBarTests.Dashboard.\(UUID().uuidString)"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    return DashboardDefaultsSuite(name: name, store: store)
  }
#endif
