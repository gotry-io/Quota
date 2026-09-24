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
  func lockScreenPrefersTheWeeklyWindowAndAddsTheSecond() {
    let weekly = OverviewWidgetContent.lockScreenWeeklyItem(from: rankedSnapshot())
    #expect(weekly?.windowTitle == "Weekly")
    #expect(weekly?.selectionID == "aaaaaaaaaaaa")
    #expect(
      OverviewWidgetContent.lockScreenSecondItem(from: rankedSnapshot())?.windowTitle == "5h"
    )
  }

  @Test
  func aConfiguredSubscriptionNarrowsTheWidgetAndAnAbsentOrUnknownOneKeepsTheRanking() {
    let snapshot = rankedSnapshot()
    let ranked = snapshot.items.map(\.selectionID)
    #expect(
      OverviewWidgetContent.select(items: snapshot.items, configuredSelectionID: nil)
        .map(\.selectionID) == ranked
    )
    #expect(
      OverviewWidgetContent.select(items: snapshot.items, configuredSelectionID: "ffffffffffff")
        .map(\.selectionID) == ranked
    )
    #expect(
      OverviewWidgetContent.mediumItems(from: snapshot, configuredSelectionID: "ffffffffffff")
        .map(\.providerID) == ["codex", "claude", "grok"]
    )

    #expect(
      OverviewWidgetContent.select(items: snapshot.items, configuredSelectionID: "bbbbbbbbbbbb")
        .map(\.selectionID) == ["bbbbbbbbbbbb"]
    )
    #expect(
      OverviewWidgetContent.primaryItem(from: snapshot, configuredSelectionID: "bbbbbbbbbbbb")?
        .providerID == "claude"
    )
    #expect(
      OverviewWidgetContent.mediumItems(from: snapshot, configuredSelectionID: "bbbbbbbbbbbb")
        .map(\.providerID) == ["claude"]
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
  func entityQueryOffersEachSubscriptionOnceAndNothingWithoutASnapshot() async throws {
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
    let found = try await query.entities(for: ["aaaaaaaaaaaa", "missingid0000"])
    #expect(found.map(\.id) == ["aaaaaaaaaaaa"])

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
