import Foundation
import QuotaWire
import Testing

@testable import QuotaBar

struct MenuBarLabelModelTests {
  private let now = Date(timeIntervalSince1970: 1_786_300_000)

  @Test
  func nothingCurrentLeavesTheQuotaMarkAlone() {
    let label = MenuBarLabelModel.make(
      overview: [],
      style: .iconAndPercent,
      provider: .automatic,
      now: now
    )

    #expect(label.icon == .quota)
    #expect(label.text == nil)
    #expect(label.accessibilityLabel == "QuotaBar")
  }

  @Test
  func percentOnlyStillShowsTheMarkWhenThereIsNoPercentToShow() {
    let label = MenuBarLabelModel.make(
      overview: [],
      style: .percent,
      provider: .automatic,
      now: now
    )

    #expect(label.icon == .quota)
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
      style: .iconAndPercent,
      provider: .automatic,
      now: now
    )

    #expect(label.icon == .quota)
    #expect(label.text == nil)
  }

  @Test
  func theTightestWindowOfEveryCurrentReadingWins() {
    let label = MenuBarLabelModel.make(
      overview: mixedProviders,
      style: .iconAndPercent,
      provider: .automatic,
      now: now
    )

    #expect(label.text == "27%")
    // The item wears the mark of the provider the number belongs to, and says so aloud.
    #expect(label.icon == .provider(.claude))
    #expect(label.accessibilityLabel == "QuotaBar, Claude Code 27% remaining")
  }

  @Test
  func oneChosenProviderAnswersEvenWhenAnotherIsTighter() {
    let label = MenuBarLabelModel.make(
      overview: mixedProviders,
      style: .iconAndPercent,
      provider: .provider(.codex),
      now: now
    )

    // Codex's own tightest window, not Claude Code's tighter one.
    #expect(label.text == "68%")
    #expect(label.icon == .provider(.codex))
    #expect(label.accessibilityLabel == "QuotaBar, Codex 68% remaining")
  }

  @Test
  func aChosenProviderWithNoCurrentReadingShowsNoOtherProvidersNumber() {
    let label = MenuBarLabelModel.make(
      overview: mixedProviders,
      style: .iconAndPercent,
      provider: .provider(.grok),
      now: now
    )

    #expect(label.text == nil)
    #expect(label.icon == .quota)
    #expect(label.accessibilityLabel == "QuotaBar")
  }

  @Test
  func theProviderChoiceOffersAutomaticAndWhateverOverviewShows() {
    let choices = MenuBarProviderPreference.choices(visibleProviders: [.grok, .codex])

    #expect(choices == [.automatic, .provider(.grok), .provider(.codex)])
    #expect(choices.map(\.label) == ["Automatic", "Grok", "Codex"])
    #expect(choices.map(\.rawValue) == ["automatic", "grok", "codex"])
  }

  @Test
  func theStoredProviderChoiceSurvivesButAnUnknownIdIsNotAChoice() {
    #expect(MenuBarProviderPreference(rawValue: "automatic") == .automatic)
    #expect(MenuBarProviderPreference(rawValue: "codex") == .provider(.codex))
    #expect(MenuBarProviderPreference(rawValue: "not_a_provider") == nil)
    #expect(MenuBarProviderPreference.fallback == .automatic)
    #expect(MenuBarProviderPreference.storageKey == "menubar.provider")
  }

  @Test
  func lowRemainingQuotaSaysSoInPunctuationBecauseTheMenuBarHasNoColor() {
    let label = MenuBarLabelModel.make(
      overview: [item(fingerprint: "codex", windows: [window(id: "weekly", usedPercent: 92)])],
      style: .iconAndPercent,
      provider: .automatic,
      now: now
    )

    #expect(label.text == "!8%")
    #expect(label.accessibilityLabel == "QuotaBar, Codex 8% remaining")
  }

  @Test
  func tenPercentIsNotYetAWarning() {
    let label = MenuBarLabelModel.make(
      overview: [item(fingerprint: "codex", windows: [window(id: "weekly", usedPercent: 90)])],
      style: .iconAndPercent,
      provider: .automatic,
      now: now
    )

    #expect(label.text == "10%")
  }

  @Test
  func everyStyleSelectsWhatTheItemShows() {
    let overview = [item(fingerprint: "codex", windows: [window(id: "weekly", usedPercent: 63)])]

    let icon = MenuBarLabelModel.make(
      overview: overview, style: .icon, provider: .automatic, now: now)
    // Icon-only is the one style that says nothing about a provider, so it wears Quota's mark.
    #expect(icon.icon == .quota)
    #expect(icon.text == nil)

    let percent = MenuBarLabelModel.make(
      overview: overview, style: .percent, provider: .automatic, now: now)
    #expect(percent.icon == nil)
    #expect(percent.text == "37%")

    let both = MenuBarLabelModel.make(
      overview: overview, style: .iconAndPercent, provider: .automatic, now: now)
    #expect(both.icon == .provider(.codex))
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
        style: .iconAndPercent,
        provider: .automatic,
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
        style: .iconAndPercent,
        provider: .automatic,
        now: now
      ).text == "45%"
    )
  }

  @Test
  func theStoredStyleKeepsItsWireSpellingAndItsKey() {
    #expect(MenuBarStylePreference.iconAndPercent.rawValue == "icon_and_percent")
    #expect(MenuBarStylePreference.fallback == .iconAndPercent)
    #expect(MenuBarStylePreference.allCases.count == 3)
    #expect(MenuBarStylePreference.storageKey == "menubar.display")
  }

  /// Codex at 68% and 74% remaining, Claude Code at 27%, and a Grok reading that aged out.
  private var mixedProviders: [LocalServiceOverviewItem] {
    [
      item(
        provider: .codex,
        fingerprint: "codex",
        windows: [
          window(id: "five_hour", usedPercent: 32),
          window(id: "weekly", usedPercent: 26),
        ]
      ),
      item(
        provider: .claude,
        fingerprint: "claude",
        windows: [window(id: "session", usedPercent: 73)]
      ),
      item(
        provider: .grok,
        fingerprint: "grok",
        windows: [window(id: "monthly", usedPercent: 5)],
        isStale: true
      ),
    ]
  }

  private func window(id: String, usedPercent: Double) -> QuotaWindow {
    QuotaWindow(id: id, title: id, usedPercent: usedPercent, limitValue: 100)
  }

  private func item(
    provider: ProviderID = .codex,
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
        provider: provider,
        fingerprint: fingerprint,
        scope: .global,
        sourceID: nil
      ),
      snapshot: QuotaSnapshot(
        provider: provider,
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
