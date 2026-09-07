import Foundation
import QuotaPresentation
import QuotaWidgetData
import QuotaWidgetProjection
import QuotaWire
import Testing

@testable import QuotaWidgetViews

/// The rule QuotaBar and Quota publish with is one rule: the same resolved readings, named by
/// each installation's own salt, come out as the same ranked rows on either platform.
struct SharedWidgetProjectionTests {
  private let now = Date(timeIntervalSince1970: 1_786_723_200)

  @Test
  func ranksTheMostConstrainedWindowFirstAndPutsBalancesLast() {
    let items = WidgetSnapshotProjection.projectItems(
      from: [
        subscription(
          provider: .claude,
          fingerprint: "fp_claude",
          windows: [
            QuotaWindow(id: "weekly", title: "Weekly", usedPercent: 20, limitValue: 100),
            QuotaWindow(id: "5h", title: "5 Hours", usedPercent: 85, limitValue: 100),
          ]
        ),
        subscription(
          provider: .openrouter,
          fingerprint: "fp_openrouter",
          windows: [
            QuotaWindow(
              id: "balance",
              title: "Balance",
              usedPercent: 0,
              remainingValue: 12.5,
              valueUnit: .usd
            )
          ]
        ),
      ],
      now: now
    )

    #expect(items.map(\.windowTitle) == ["5 Hours", "Weekly", "Balance"])
    #expect(items.map(\.remainingPercent) == [15, 80, 100])
    #expect(items.last?.hasLimit == false)
    #expect(items.allSatisfy { $0.selectionID.count == WidgetQuotaItem.selectionIDLength })
  }

  @Test
  func aSaltRenamesEverySubscriptionWithoutChangingTheReadings() {
    let readings = [
      subscription(
        provider: .codex,
        fingerprint: "fp_codex",
        windows: [QuotaWindow(id: "weekly", title: "Weekly", usedPercent: 40, limitValue: 100)]
      )
    ]
    let mine = WidgetSnapshotProjection.projectItems(from: readings, now: now)
    let theirs = WidgetSnapshotProjection.projectItems(
      from: readings.map {
        WidgetProjectionSubscription(
          snapshot: $0.snapshot,
          selectionID: SelectionIDs.make(
            selector: $0.sourceKey,
            salt: Data(repeating: 0x11, count: 32)
          ),
          sourceKey: $0.sourceKey
        )
      },
      now: now
    )

    #expect(mine.map(\.remainingPercent) == theirs.map(\.remainingPercent))
    #expect(mine.map(\.selectionID) != theirs.map(\.selectionID))
  }

  @Test
  func todayUsageIsUnavailableWhenTheClientHasNoneToPublish() {
    let snapshot = WidgetSnapshotProjection.make(subscriptions: [], today: nil, fetchedAt: now)
    #expect(snapshot.items.isEmpty)
    #expect(snapshot.today.cost.status == .unavailable)
    #expect(snapshot.isValid)
  }

  /// The desktop offers small, medium, and large; every one of them draws from the same ranked
  /// items the phone's families do.
  @Test
  func desktopFamiliesSelectFromTheSameRankedItems() {
    let published = WidgetSnapshotProjection.make(
      subscriptions: [
        subscription(
          provider: .codex,
          fingerprint: "fp_codex",
          windows: [
            QuotaWindow(id: "5h", title: "5 Hours", usedPercent: 90, limitValue: 100),
            QuotaWindow(id: "weekly", title: "Weekly", usedPercent: 30, limitValue: 100),
          ]
        ),
        subscription(
          provider: .claude,
          fingerprint: "fp_claude",
          windows: [QuotaWindow(id: "weekly", title: "Weekly", usedPercent: 50, limitValue: 100)]
        ),
      ],
      today: nil,
      fetchedAt: now
    )

    #expect(
      OverviewWidgetContent.smallItems(from: published).map(\.windowTitle)
        == ["5 Hours", "Weekly"]
    )
    #expect(
      OverviewWidgetContent.mediumItems(from: published).map(\.providerID) == ["codex", "claude"]
    )
    #expect(
      OverviewWidgetContent.largeProviderGroups(from: published).map(\.providerID)
        == ["codex", "claude"]
    )
  }

  /// Every platform draws the same two paths; only the scheme its app registers differs.
  @Test
  func widgetLinksUseTheSchemeThisPlatformsAppAnswers() {
    #if os(macOS)
      #expect(OverviewWidgetContent.urlScheme == "quotabar")
    #else
      #expect(OverviewWidgetContent.urlScheme == "io.gotry.quota")
    #endif
    let scheme = OverviewWidgetContent.urlScheme
    #expect(OverviewWidgetContent.overviewURL.absoluteString == "\(scheme):/overview")

    let published = WidgetSnapshotProjection.make(
      subscriptions: [
        subscription(
          provider: .codex,
          fingerprint: "fp_codex",
          windows: [
            QuotaWindow(id: "5h", title: "5 Hours", usedPercent: 90, limitValue: 100),
            QuotaWindow(id: "weekly", title: "Weekly", usedPercent: 30, limitValue: 100),
          ]
        ),
        subscription(
          provider: .claude,
          fingerprint: "fp_claude",
          windows: [QuotaWindow(id: "weekly", title: "Weekly", usedPercent: 50, limitValue: 100)]
        ),
      ],
      today: nil,
      fetchedAt: now
    )
    let item = published.items[0]
    #expect(
      OverviewWidgetContent.subscriptionURL(for: item).absoluteString
        == "\(scheme):/subscriptions/\(item.selectionID)"
    )
    // One subscription on screen opens that subscription; several keep Overview.
    #expect(
      OverviewWidgetContent.widgetURL(for: OverviewWidgetContent.smallItems(from: published))
        == OverviewWidgetContent.subscriptionURL(for: item)
    )
    #expect(
      OverviewWidgetContent.widgetURL(for: OverviewWidgetContent.mediumItems(from: published))
        == OverviewWidgetContent.overviewURL
    )
  }

  private func subscription(
    provider: ProviderID,
    fingerprint: String,
    windows: [QuotaWindow]
  ) -> WidgetProjectionSubscription {
    let selector = SubscriptionSelector.make(
      provider: provider.rawValue,
      fingerprint: fingerprint,
      fingerprintScope: "global",
      sourceID: nil
    )
    return WidgetProjectionSubscription(
      snapshot: QuotaSnapshot(
        provider: provider,
        account: QuotaAccount(fingerprint: fingerprint, fingerprintScope: .global),
        windows: windows,
        status: .available,
        observedAt: now
      ),
      selectionID: SelectionIDs.make(selector: selector, salt: Data(repeating: 0x5a, count: 32)),
      sourceKey: selector
    )
  }
}
