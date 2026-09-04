import Foundation
import QuotaWidgetData
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

    let oversize = Data(repeating: 0x41, count: ProtectedFileWidgetSnapshotStore.maximumLoadBytes * 2)
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
    let first = WidgetQuotaItem(
      selectionID: "aaaaaaaaaaaa",
      providerID: "codex",
      providerDisplayName: "Codex",
      windowTitle: "5h",
      remainingPercent: 20,
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
    let snapshot = WidgetSnapshot(
      fetchedAt: date("2026-08-14T16:00:00Z"),
      items: [first, second, third],
      today: WidgetTodayUsage(
        inputTokens: 1_200,
        outputTokens: 340,
        cost: WidgetCost(status: .complete, amountMicrousd: "3138")
      )
    )

    #expect(OverviewWidgetContent.primaryItem(from: snapshot)?.providerID == "codex")
    #expect(OverviewWidgetContent.mediumItems(from: snapshot).map(\.providerID) == ["codex", "claude"])
    #expect(OverviewWidgetContent.primaryItem(from: nil) == nil)
    #expect(OverviewWidgetContent.mediumItems(from: nil).isEmpty)
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
  func agesUseTheSharedRelativePhrases() {
    let now = date("2026-08-14T16:00:00Z")
    let fetched = date("2026-08-14T15:45:00Z")
    let resets = date("2026-08-14T18:00:00Z")
    #expect(OverviewWidgetContent.updated(fetchedAt: fetched, now: now) == "Updated 15m ago")
    #expect(OverviewWidgetContent.resetAge(resetsAt: resets, now: now) == "2h")
  }

  @Test
  func resetAgeReturnsNowCopyAfterResetInstant() {
    let now = date("2026-08-14T16:00:00Z")
    let atInstant = now
    let past = date("2026-08-14T15:59:00Z")
    #expect(OverviewWidgetContent.resetAge(resetsAt: atInstant, now: now) == "now")
    #expect(OverviewWidgetContent.resetAge(resetsAt: past, now: now) == "now")
    #expect(OverviewWidgetContent.resetAge(resetsAt: past, now: now) != "0s")
    #expect(OverviewWidgetContent.resetDueCopy == "now")
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
