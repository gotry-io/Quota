import Foundation
import QuotaPresentation
import QuotaWidgetData
import QuotaWidgetViews
import Testing

@testable import Quota

struct OverviewWidgetContentTests {
  @Test
  func loadSnapshotReturnsNilForMissingCorruptAndOversize() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(OverviewWidgetContent.loadSnapshot(containerURL: directory) == nil)

    let store = ProtectedFileWidgetSnapshotStore(directory: directory)
    try Data("not-json".utf8).write(to: store.fileURL)
    #expect(OverviewWidgetContent.loadSnapshot(containerURL: directory) == nil)

    let oversize = Data(
      repeating: 0x41, count: ProtectedFileWidgetSnapshotStore.maximumLoadBytes * 2)
    try oversize.write(to: store.fileURL)
    #expect(OverviewWidgetContent.loadSnapshot(containerURL: directory) == nil)
  }

  @Test
  func loadSnapshotReturnsValidSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let snapshot = makeSnapshot()
    let store = ProtectedFileWidgetSnapshotStore(directory: directory)
    try store.save(snapshot)

    let loaded = OverviewWidgetContent.loadSnapshot(containerURL: directory)
    #expect(loaded == snapshot)
  }

  @Test
  func primaryItemAndMediumItemsPreferMostConstrainedOrder() {
    let snapshot = rankedSnapshot()

    #expect(OverviewWidgetContent.primaryItem(from: snapshot)?.providerID == "codex")
    #expect(
      OverviewWidgetContent.mediumItems(from: snapshot).map(\.providerID)
        == ["codex", "claude", "grok"]
    )
    #expect(OverviewWidgetContent.primaryItem(from: nil) == nil)
    #expect(OverviewWidgetContent.mediumItems(from: nil).isEmpty)
  }

  @Test
  func smallItemsAreTwoWindowsOfTheMostConstrainedSubscription() {
    let items = OverviewWidgetContent.smallItems(from: rankedSnapshot())
    #expect(items.map(\.windowTitle) == ["5h", "Weekly"])
    #expect(items.map(\.selectionID) == ["aaaaaaaaaaaa", "aaaaaaaaaaaa"])
    #expect(OverviewWidgetContent.smallItems(from: nil).isEmpty)
  }

  @Test
  func lockScreenPrefersTheWeeklyWindowAndAddsTheSecond() {
    let weekly = OverviewWidgetContent.lockScreenWeeklyItem(from: rankedSnapshot())
    #expect(weekly?.windowTitle == "Weekly")
    #expect(weekly?.selectionID == "aaaaaaaaaaaa")
    #expect(
      OverviewWidgetContent.lockScreenSecondItem(from: rankedSnapshot())?.windowTitle == "5h"
    )
  }

  @Test
  func lockScreenURLOpensTheFocusedSubscriptionAndOverviewWithoutOne() {
    let weekly = OverviewWidgetContent.lockScreenWeeklyItem(from: rankedSnapshot())!
    #expect(
      OverviewWidgetContent.lockScreenURL(from: rankedSnapshot())
        == OverviewWidgetContent.subscriptionURL(for: weekly)
    )
    #expect(OverviewWidgetContent.lockScreenURL(from: nil) == OverviewWidgetContent.overviewURL)
  }

  @Test
  func selectKeepsRankedItemsForAutomatic() {
    let items = rankedSnapshot().items
    let selected = OverviewWidgetContent.select(items: items, configuredSelectionID: nil)
    #expect(selected.map(\.selectionID) == items.map(\.selectionID))
    #expect(
      OverviewWidgetContent.primaryItem(from: rankedSnapshot())?.selectionID == "aaaaaaaaaaaa")
  }

  @Test
  func selectReturnsWindowsOfTheConfiguredSubscription() {
    let items = rankedSnapshot().items
    let selected = OverviewWidgetContent.select(
      items: items,
      configuredSelectionID: "bbbbbbbbbbbb"
    )
    #expect(selected.map(\.selectionID) == ["bbbbbbbbbbbb"])
    #expect(
      OverviewWidgetContent.primaryItem(
        from: rankedSnapshot(),
        configuredSelectionID: "bbbbbbbbbbbb"
      )?.providerID == "claude"
    )
    #expect(
      OverviewWidgetContent.mediumItems(
        from: rankedSnapshot(),
        configuredSelectionID: "bbbbbbbbbbbb"
      ).map(\.providerID) == ["claude"]
    )
  }

  @Test
  func selectFallsBackToAutomaticWhenConfiguredIdIsMissing() {
    let snapshot = rankedSnapshot()
    let selected = OverviewWidgetContent.select(
      items: snapshot.items,
      configuredSelectionID: "ffffffffffff"
    )
    #expect(selected.map(\.selectionID) == snapshot.items.map(\.selectionID))
    #expect(
      OverviewWidgetContent.primaryItem(
        from: snapshot,
        configuredSelectionID: "ffffffffffff"
      )?.providerID == "codex"
    )
    #expect(
      OverviewWidgetContent.mediumItems(
        from: snapshot,
        configuredSelectionID: "ffffffffffff"
      ).map(\.providerID) == ["codex", "claude", "grok"]
    )
  }

  @Test
  func largeGroupsCapAtThreeProvidersAndTwoWindows() {
    let providers = ["codex", "claude", "grok", "gemini"]
    let items = providers.enumerated().flatMap { providerIndex, providerID in
      (0..<3).map { windowIndex in
        WidgetQuotaItem(
          selectionID: String(repeating: String(format: "%x", providerIndex), count: 12),
          providerID: providerID,
          providerDisplayName: providerID,
          windowTitle: "W\(windowIndex)",
          remainingPercent: Double(providerIndex * 10 + windowIndex),
          hasLimit: true
        )
      }
    }
    let snapshot = WidgetSnapshot(
      fetchedAt: date("2026-08-14T16:00:00Z"),
      items: items,
      today: WidgetTodayUsage(
        inputTokens: 0,
        outputTokens: 0,
        cost: WidgetCost(status: .unavailable)
      )
    )
    let groups = OverviewWidgetContent.largeProviderGroups(from: snapshot)
    #expect(groups.map(\.providerID) == ["codex", "claude", "grok"])
    #expect(groups.allSatisfy { $0.items.count == 2 })
    #expect(OverviewWidgetContent.largeItems(from: snapshot).count == 6)
    let configuredID = items.last?.selectionID
    let configured = OverviewWidgetContent.largeItems(
      from: snapshot,
      configuredSelectionID: configuredID
    )
    #expect(configured.map(\.providerID) == ["gemini", "gemini"])
    #expect(configured.count == 2)
  }

  @Test
  func widgetURLUsesSubscriptionForASingleItemAndOverviewForSeveral() {
    let ranked = rankedSnapshot().items
    let first = ranked[0]
    let second = ranked.first { $0.selectionID != first.selectionID }!
    #expect(
      OverviewWidgetContent.widgetURL(for: [first])
        == OverviewWidgetContent.subscriptionURL(for: first)
    )
    #expect(
      OverviewWidgetContent.widgetURL(for: [first, second]) == OverviewWidgetContent.overviewURL)
    #expect(OverviewWidgetContent.widgetURL(for: []) == OverviewWidgetContent.overviewURL)
    let sameSubscription = OverviewWidgetContent.smallItems(from: rankedSnapshot())
    #expect(
      OverviewWidgetContent.widgetURL(for: sameSubscription)
        == OverviewWidgetContent.subscriptionURL(for: first)
    )
  }

  @Test
  func formatsPrimaryRemainingAndTodayCompactLabels() {
    let percentItem = WidgetQuotaItem(
      selectionID: "0123456789ab",
      providerID: "codex",
      providerDisplayName: "Codex",
      windowTitle: "Weekly",
      remainingPercent: 71,
      remainingValue: 3.75,
      unit: .usd,
      hasLimit: true
    )
    #expect(OverviewWidgetContent.remainingLabel(for: percentItem) == "71% · $3.75")
    #expect(
      OverviewWidgetContent.remainingAccessibility(for: percentItem)
        == "Weekly, 71% · $3.75 remaining"
    )
    #expect(OverviewWidgetContent.inlineLabel(for: percentItem) == "Weekly 29%")
    #expect(OverviewWidgetContent.usedPercentLabel(for: percentItem) == "29%")

    let balanceItem = WidgetQuotaItem(
      selectionID: "fedcba987654",
      providerID: "openrouter",
      providerDisplayName: "OpenRouter",
      windowTitle: "Balance",
      remainingPercent: 100,
      remainingValue: 12.5,
      unit: .usd,
      hasLimit: false
    )
    #expect(OverviewWidgetContent.remainingLabel(for: balanceItem) == "$12.50")
    #expect(OverviewWidgetContent.isBalanceOnly(balanceItem))
    #expect(OverviewWidgetContent.inlineLabel(for: balanceItem) == "Balance 0%")

    let extraUsage = WidgetQuotaItem(
      selectionID: "abcdef012345",
      providerID: "claude",
      providerDisplayName: "Claude Code",
      windowTitle: "Extra Usage",
      remainingPercent: 87.5,
      remainingValue: 87.5,
      limitValue: 100,
      unit: .usd,
      hasLimit: true
    )
    #expect(OverviewWidgetContent.remainingLabel(for: extraUsage) == "$87.50 of $100.00")
    #expect(!OverviewWidgetContent.showsPercentMeter(extraUsage))
    #expect(!OverviewWidgetContent.isBalanceOnly(extraUsage))

    let cost = WidgetCost(status: .partial, amountMicrousd: "50239770")
    #expect(OverviewWidgetContent.costLabel(for: cost).hasPrefix("≥"))
    #expect(
      OverviewWidgetContent.todayTokensLabel(input: 1_200, output: 340).contains("in")
    )
  }

  @Test
  func timelineRefreshIsFifteenMinutes() {
    let now = date("2026-08-14T16:00:00Z")
    let next = OverviewWidgetContent.nextRefreshDate(from: now)
    #expect(next.timeIntervalSince(now) == OverviewWidgetContent.refreshInterval)
    #expect(OverviewWidgetContent.refreshInterval == 15 * 60)
  }

  @Test
  func largeUpdatedFooterUsesTheSharedPhraseWhenASnapshotExists() {
    let snapshot = rankedSnapshot()
    let now = date("2026-08-14T16:00:00Z")
    #expect(
      OverviewWidgetContent.updated(fetchedAt: snapshot.fetchedAt, now: now) == "Updated just now"
    )
    #expect(OverviewWidgetContent.largeItems(from: snapshot).count == 4)
  }

  @Test
  func agesUseTheSharedRelativePhrases() {
    let now = date("2026-08-14T16:00:00Z")
    let fetched = date("2026-08-14T15:45:00Z")
    let resets = date("2026-08-14T18:00:00Z")
    #expect(OverviewWidgetContent.updated(fetchedAt: fetched, now: now) == "Updated 15m ago")
    #expect(FreshnessCopy.resetCopy(resetsAt: resets, now: now) == "Resets in 2h")
  }

  @Test
  func liveCountdownIsOnlyForAFutureResetUnderADay() {
    let now = date("2026-08-14T16:00:00Z")
    #expect(
      OverviewWidgetContent.usesLiveResetCountdown(
        resetsAt: now.addingTimeInterval(3_600),
        now: now
      )
    )
    #expect(
      OverviewWidgetContent.usesLiveResetCountdown(
        resetsAt: now.addingTimeInterval(86_399),
        now: now
      )
    )
    #expect(
      !OverviewWidgetContent.usesLiveResetCountdown(
        resetsAt: now.addingTimeInterval(86_400),
        now: now
      )
    )
    #expect(!OverviewWidgetContent.usesLiveResetCountdown(resetsAt: now, now: now))
    #expect(
      !OverviewWidgetContent.usesLiveResetCountdown(
        resetsAt: now.addingTimeInterval(-1),
        now: now
      )
    )
    let utc = TimeZone(secondsFromGMT: 0)!
    #expect(
      FreshnessCopy.resetCopy(
        resetsAt: now.addingTimeInterval(200_000),
        now: now,
        timeZone: utc
      ) != nil
    )
    #expect(FreshnessCopy.resetCopy(resetsAt: now, now: now) == nil)
  }

  @Test
  func aPastResetPrintsNoResetsLine() {
    let now = date("2026-08-14T16:00:00Z")
    let atInstant = now
    let past = date("2026-08-14T15:59:00Z")
    #expect(FreshnessCopy.resetCopy(resetsAt: atInstant, now: now) == nil)
    #expect(FreshnessCopy.resetCopy(resetsAt: past, now: now) == nil)
    let item = WidgetQuotaItem(
      selectionID: "0123456789ab",
      providerID: "codex",
      providerDisplayName: "Codex",
      windowTitle: "Weekly",
      remainingPercent: 71,
      hasLimit: true,
      resetsAt: past
    )
    #expect(
      !OverviewWidgetContent.itemAccessibility(item: item, fetchedAt: nil, now: now)
        .contains("Resets")
    )
  }

  @Test
  func paceRunsOutIsReservedOnTheItem() {
    let item = WidgetQuotaItem(
      selectionID: "0123456789ab",
      providerID: "codex",
      providerDisplayName: "Codex",
      windowTitle: "Weekly",
      remainingPercent: 20,
      hasLimit: true,
      pace: .runsOut(
        QuotaPaceProjection(tempo: .ahead, deltaPercent: 42, projectedAtReset: 142),
        exhaustsAt: date("2026-08-14T17:00:00Z")
      )
    )
    #expect(OverviewWidgetContent.paceRunsOut(item))
    #expect(
      !OverviewWidgetContent.paceRunsOut(
        WidgetQuotaItem(
          selectionID: "0123456789ab",
          providerID: "codex",
          providerDisplayName: "Codex",
          windowTitle: "Weekly",
          remainingPercent: 20,
          hasLimit: true,
          pace: .lasts(
            QuotaPaceProjection(tempo: .onTrack, deltaPercent: 0, projectedAtReset: 90)
          )
        )
      )
    )
  }

  @Test
  func subscriptionURLUsesTheSelectionIdPath() {
    let item = WidgetQuotaItem(
      selectionID: "ccfc96629357",
      providerID: "codex",
      providerDisplayName: "Codex",
      windowTitle: "Weekly",
      remainingPercent: 71,
      hasLimit: true
    )
    #expect(
      OverviewWidgetContent.subscriptionURL(for: item)
        == URL(string: "io.gotry.quota:/subscriptions/ccfc96629357")
    )
    #expect(OverviewWidgetContent.overviewURL == URL(string: "io.gotry.quota:/overview")!)
  }

  @Test
  func entityQueryReadsCandidatesFromAnInjectedSnapshot() async throws {
    let snapshot = rankedSnapshot()
    let query = SubscriptionEntityQuery(loadSnapshot: { snapshot })
    let suggested = try await query.suggestedEntities()
    #expect(suggested.map(\.id) == ["aaaaaaaaaaaa", "bbbbbbbbbbbb", "cccccccccccc"])
    #expect(suggested.map(\.displayName) == ["Codex · 5h", "Claude · Weekly", "Grok · Weekly"])
    #expect(suggested.allSatisfy { !$0.displayName.contains("octocat") })

    let found = try await query.entities(for: ["bbbbbbbbbbbb", "missingid0000"])
    #expect(found.map(\.id) == ["bbbbbbbbbbbb"])
    #expect(found.first?.displayName == "Claude · Weekly")

    #expect(await query.defaultResult() == nil)
  }

  @Test
  func entityQueryDedupesSelectionIdsAndReturnsEmptyWithoutASnapshot() async throws {
    let first = WidgetQuotaItem(
      selectionID: "aaaaaaaaaaaa",
      providerID: "codex",
      providerDisplayName: "Codex",
      windowTitle: "5 Hours",
      remainingPercent: 20,
      hasLimit: true
    )
    let secondWindow = WidgetQuotaItem(
      selectionID: "aaaaaaaaaaaa",
      providerID: "codex",
      providerDisplayName: "Codex",
      windowTitle: "Weekly",
      remainingPercent: 40,
      hasLimit: true
    )
    let snapshot = WidgetSnapshot(
      fetchedAt: date("2026-08-14T16:00:00Z"),
      items: [first, secondWindow],
      today: WidgetTodayUsage(
        inputTokens: 0,
        outputTokens: 0,
        cost: WidgetCost(status: .unavailable)
      )
    )
    let query = SubscriptionEntityQuery(loadSnapshot: { snapshot })
    let suggested = try await query.suggestedEntities()
    #expect(suggested.map(\.id) == ["aaaaaaaaaaaa"])
    #expect(suggested.first?.displayName == "Codex · 5 Hours")

    let empty = SubscriptionEntityQuery(loadSnapshot: { nil })
    #expect(try await empty.suggestedEntities().isEmpty)
    #expect(try await empty.entities(for: ["aaaaaaaaaaaa"]).isEmpty)
  }

  private func rankedSnapshot() -> WidgetSnapshot {
    let first = WidgetQuotaItem(
      selectionID: "aaaaaaaaaaaa",
      providerID: "codex",
      providerDisplayName: "Codex",
      windowTitle: "5h",
      remainingPercent: 20,
      hasLimit: true
    )
    let firstWeekly = WidgetQuotaItem(
      selectionID: "aaaaaaaaaaaa",
      providerID: "codex",
      providerDisplayName: "Codex",
      windowTitle: "Weekly",
      remainingPercent: 60,
      hasLimit: true
    )
    let second = WidgetQuotaItem(
      selectionID: "bbbbbbbbbbbb",
      providerID: "claude",
      providerDisplayName: "Claude",
      windowTitle: "Weekly",
      remainingPercent: 40,
      hasLimit: true
    )
    let third = WidgetQuotaItem(
      selectionID: "cccccccccccc",
      providerID: "grok",
      providerDisplayName: "Grok",
      windowTitle: "Weekly",
      remainingPercent: 80,
      hasLimit: true
    )
    return WidgetSnapshot(
      fetchedAt: date("2026-08-14T16:00:00Z"),
      items: [first, firstWeekly, second, third],
      today: WidgetTodayUsage(
        inputTokens: 1_200,
        outputTokens: 340,
        cost: WidgetCost(status: .complete, amountMicrousd: "3138")
      )
    )
  }

  private func makeSnapshot() -> WidgetSnapshot {
    WidgetSnapshot(
      fetchedAt: date("2026-08-14T16:00:00Z"),
      items: [
        WidgetQuotaItem(
          selectionID: "0123456789ab",
          providerID: "codex",
          providerDisplayName: "Codex",
          windowTitle: "Weekly",
          remainingPercent: 71,
          hasLimit: true
        )
      ],
      today: WidgetTodayUsage(
        inputTokens: 1000,
        outputTokens: 200,
        cost: WidgetCost(status: .complete, amountMicrousd: "3138")
      )
    )
  }

  private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
  }
}

@Test
func aReportedFailureIsNamedEvenWhenTheReadingStillCarriesAReset() {
  let item = WidgetQuotaItem(
    selectionID: "0123456789ab",
    providerID: "codex",
    providerDisplayName: "Codex",
    windowTitle: "Weekly",
    remainingPercent: 71,
    resetsAt: Date(timeIntervalSince1970: 1_786_000_000 + 3_600),
    state: .signInNeeded
  )

  let label = OverviewWidgetContent.itemAccessibility(
    item: item,
    fetchedAt: nil,
    now: Date(timeIntervalSince1970: 1_786_000_000)
  )

  // The reset it names may already have passed, so the reason comes first.
  #expect(label.contains("Sign-in needed"))
  #expect(label.range(of: "Sign-in needed")!.lowerBound < label.range(of: "Resets")!.lowerBound)
}
