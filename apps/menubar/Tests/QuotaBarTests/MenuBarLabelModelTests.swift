import Foundation
import QuotaWire
import Testing

@testable import QuotaBar

struct MenuBarLabelModelTests {
  private let now = Date(timeIntervalSince1970: 1_786_300_000)

  @Test
  func nothingCurrentLeavesTheIconAlone() {
    let label = MenuBarLabelModel.make(
      overview: [],
      preference: .iconAndPercent,
      now: now
    )

    #expect(label.showsIcon)
    #expect(label.text == nil)
    #expect(label.accessibilityLabel == "QuotaBar")
  }

  @Test
  func percentOnlyStillShowsTheIconWhenThereIsNoPercentToShow() {
    let label = MenuBarLabelModel.make(overview: [], preference: .percent, now: now)

    #expect(label.showsIcon)
    #expect(label.text == nil)
  }

  @Test
  func readingsThatNoLongerDescribeLiveQuotaAnswerForNothing() {
    let serviceStale = item(
      fingerprint: "aged_out_by_service",
      windows: [window(id: "weekly", usedPercent: 95)],
      isStale: true
    )
    let agedOut = item(
      fingerprint: "aged_out_by_freshness",
      windows: [window(id: "weekly", usedPercent: 90)],
      observedAt: now.addingTimeInterval(-90_000)
    )
    let failed = item(
      fingerprint: "sign_in_needed",
      windows: [window(id: "weekly", usedPercent: 99)],
      status: .authRequired
    )

    let label = MenuBarLabelModel.make(
      overview: [serviceStale, agedOut, failed],
      preference: .iconAndPercent,
      now: now
    )

    #expect(label.showsIcon)
    #expect(label.text == nil)
  }

  @Test
  func theTightestWindowOfEveryCurrentReadingWins() {
    let overview = [
      item(
        fingerprint: "codex",
        windows: [
          window(id: "five_hour", usedPercent: 32),
          window(id: "weekly", usedPercent: 16),
        ]
      ),
      item(fingerprint: "claude", windows: [window(id: "session", usedPercent: 47)]),
      item(fingerprint: "grok", windows: [window(id: "monthly", usedPercent: 73)]),
      item(
        fingerprint: "stale_and_tighter",
        windows: [window(id: "weekly", usedPercent: 99)],
        isStale: true
      ),
    ]

    let label = MenuBarLabelModel.make(overview: overview, preference: .iconAndPercent, now: now)

    #expect(label.text == "27%")
    #expect(label.accessibilityLabel == "QuotaBar, 27% remaining")
  }

  @Test
  func lowRemainingQuotaSaysSoInPunctuationBecauseTheMenuBarHasNoColor() {
    let label = MenuBarLabelModel.make(
      overview: [item(fingerprint: "codex", windows: [window(id: "weekly", usedPercent: 92)])],
      preference: .iconAndPercent,
      now: now
    )

    #expect(label.text == "!8%")
    #expect(label.accessibilityLabel == "QuotaBar, 8% remaining")
  }

  @Test
  func tenPercentIsNotYetAWarning() {
    let label = MenuBarLabelModel.make(
      overview: [item(fingerprint: "codex", windows: [window(id: "weekly", usedPercent: 90)])],
      preference: .iconAndPercent,
      now: now
    )

    #expect(label.text == "10%")
  }

  @Test
  func everyPreferenceSelectsWhatTheItemShows() {
    let overview = [item(fingerprint: "codex", windows: [window(id: "weekly", usedPercent: 63)])]

    let icon = MenuBarLabelModel.make(overview: overview, preference: .icon, now: now)
    #expect(icon.showsIcon)
    #expect(icon.text == nil)

    let percent = MenuBarLabelModel.make(overview: overview, preference: .percent, now: now)
    #expect(!percent.showsIcon)
    #expect(percent.text == "37%")

    let both = MenuBarLabelModel.make(overview: overview, preference: .iconAndPercent, now: now)
    #expect(both.showsIcon)
    #expect(both.text == "37%")
  }

  @Test
  func aWalletBalanceIsNotAPercentAndCannotBeTheConstraint() {
    let balanceOnly = item(
      fingerprint: "cursor_balance",
      windows: [
        QuotaWindow(
          id: "included_usage",
          title: "Balance",
          usedPercent: 0,
          remainingValue: 3.75,
          valueUnit: .usd
        )
      ]
    )

    #expect(
      MenuBarLabelModel.make(
        overview: [balanceOnly],
        preference: .iconAndPercent,
        now: now
      ).text == nil
    )

    let withMeter = item(
      fingerprint: "codex",
      windows: [window(id: "weekly", usedPercent: 55)]
    )
    #expect(
      MenuBarLabelModel.make(
        overview: [balanceOnly, withMeter],
        preference: .iconAndPercent,
        now: now
      ).text == "45%"
    )
  }

  @Test
  func theStoredPreferenceKeepsItsWireSpelling() {
    #expect(MenuBarDisplayPreference.iconAndPercent.rawValue == "icon_and_percent")
    #expect(MenuBarDisplayPreference.fallback == .iconAndPercent)
    #expect(MenuBarDisplayPreference.allCases.count == 3)
  }

  private func window(id: String, usedPercent: Double) -> QuotaWindow {
    QuotaWindow(id: id, title: id, usedPercent: usedPercent, limitValue: 100)
  }

  private func item(
    fingerprint: String,
    windows: [QuotaWindow],
    status: QuotaStatus = .available,
    observedAt: Date? = nil,
    isStale: Bool = false
  ) -> LocalServiceOverviewItem {
    let source = LocalServiceOverviewSource(
      sourceID: "local",
      kind: .local,
      deviceID: nil,
      displayName: "This Mac",
      observedAt: observedAt ?? now,
      isStale: isStale
    )
    return LocalServiceOverviewItem(
      identity: LocalServiceOverviewIdentity(
        provider: .codex,
        fingerprint: fingerprint,
        scope: .global,
        sourceID: nil
      ),
      snapshot: QuotaSnapshot(
        provider: .codex,
        account: QuotaAccount(
          fingerprint: fingerprint,
          label: nil,
          plan: nil,
          fingerprintScope: .global
        ),
        windows: windows,
        status: status,
        observedAt: observedAt ?? now
      ),
      sources: [source],
      selectedSourceID: source.sourceID,
      selectedSourceDisplayName: source.displayName,
      isStale: isStale
    )
  }
}
