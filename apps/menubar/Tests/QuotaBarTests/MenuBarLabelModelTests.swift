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
    #expect(MenuBarProviderPreference(rawValue: "codex,claude") == .providers([.codex, .claude]))
    #expect(MenuBarProviderPreference(rawValue: "not_a_provider") == nil)
    #expect(MenuBarProviderPreference.fallback == .automatic)
    #expect(MenuBarProviderPreference.storageKey == "menubar.provider")
    #expect(MenuBarProviderPreference.combinedLimit == 3)
  }

  @Test
  func togglingNamedProvidersLeavesAutomaticWhenTheSetIsEmpty() {
    let visible: [ProviderID] = [.grok, .codex, .claude]
    let one = MenuBarProviderPreference.automatic.toggling(.codex, visibleProviders: visible)
    #expect(one == .provider(.codex))
    let two = one.toggling(.claude, visibleProviders: visible)
    #expect(two.selected == [.codex, .claude])
    let none = two.toggling(.codex, visibleProviders: visible).toggling(
      .claude, visibleProviders: visible)
    #expect(none == .automatic)
  }

  @Test
  func lowRemainingQuotaIsStillAPercent() {
    let label = MenuBarLabelModel.make(
      overview: [item(fingerprint: "codex", windows: [window(id: "weekly", usedPercent: 92)])],
      style: .iconAndPercent,
      provider: .automatic,
      now: now
    )

    #expect(label.text == "8%")
    #expect(label.accessibilityLabel == "QuotaBar, Codex 8% remaining")
  }

  @Test
  func tenPercentIsAPercentLikeAnyOther() {
    let label = MenuBarLabelModel.make(
      overview: [item(fingerprint: "codex", windows: [window(id: "weekly", usedPercent: 90)])],
      style: .iconAndPercent,
      provider: .automatic,
      now: now
    )

    #expect(label.text == "10%")
  }

  @Test
  func combinedPacksTwoReadingsIntoOneItemAndSeparateDoesNot() {
    let combined = MenuBarLabelModel.specs(
      overview: mixedProviders,
      style: .iconAndPercent,
      provider: .providers([.codex, .claude]),
      arrangement: .combined,
      visibleProviders: [.codex, .claude, .grok],
      now: now
    )
    #expect(combined.count == 1)
    #expect(combined[0].id == .combined)
    #expect(combined[0].label.cells.count == 2)
    #expect(combined[0].label.cells[0] == MenuBarLabelCell(icon: .provider(.codex), text: "68%"))
    #expect(combined[0].label.cells[1] == MenuBarLabelCell(icon: .provider(.claude), text: "27%"))
    #expect(
      combined[0].label.accessibilityLabel
        == "QuotaBar, Codex 68% remaining, Claude Code 27% remaining"
    )

    let separate = MenuBarLabelModel.specs(
      overview: mixedProviders,
      style: .percent,
      provider: .providers([.codex, .claude]),
      arrangement: .separate,
      visibleProviders: [.codex, .claude, .grok],
      now: now
    )
    #expect(separate.map(\.id) == [.provider(.codex), .provider(.claude)])
    #expect(separate[0].label.icon == .provider(.codex))
    #expect(separate[0].label.text == "68%")
    #expect(separate[1].label.text == "27%")
  }

  @Test
  func combinedKeepsAStaleProvidersMarkAndDoesNotBorrowAnotherNumber() {
    let specs = MenuBarLabelModel.specs(
      overview: mixedProviders,
      style: .iconAndPercent,
      provider: .providers([.claude, .grok]),
      arrangement: .combined,
      visibleProviders: [.codex, .claude, .grok],
      now: now
    )
    #expect(specs.count == 1)
    #expect(specs[0].label.cells == [
      MenuBarLabelCell(icon: .provider(.claude), text: "27%"),
      MenuBarLabelCell(icon: .provider(.grok), text: nil),
    ])
  }

  @Test
  func moreThanThreeNamedProvidersCannotStayCombined() {
    let specs = MenuBarLabelModel.specs(
      overview: mixedProviders + [
        item(
          provider: .cursor,
          fingerprint: "cursor",
          windows: [window(id: "weekly", usedPercent: 40)]
        )
      ],
      style: .iconAndPercent,
      provider: .providers([.codex, .claude, .cursor, .grok]),
      arrangement: .combined,
      visibleProviders: [.codex, .claude, .grok, .cursor],
      now: now
    )
    #expect(specs.map(\.id) == [
      .provider(.codex), .provider(.claude), .provider(.grok), .provider(.cursor),
    ])
  }

  @Test
  func layoutResolvesVisibleProvidersWithoutRewritingTheStoredChoice() {
    let visible: [ProviderID] = [.codex, .claude, .grok]
    #expect(
      MenuBarLayout.resolve(
        selection: .automatic,
        arrangement: .separate,
        visibleProviders: visible
      ) == .automatic
    )
    #expect(
      MenuBarLayout.resolve(
        selection: .provider(.codex),
        arrangement: .combined,
        visibleProviders: visible
      ) == .items([.codex])
    )
    #expect(
      MenuBarLayout.resolve(
        selection: .providers([.codex, .claude]),
        arrangement: .combined,
        visibleProviders: visible
      ) == .packed([.codex, .claude])
    )
    #expect(
      MenuBarLayout.resolve(
        selection: .providers([.codex, .claude, .cursor, .grok]),
        arrangement: .combined,
        visibleProviders: [.codex, .claude, .grok, .cursor]
      ) == .items([.codex, .claude, .grok, .cursor])
    )
    #expect(
      MenuBarLayout.resolve(
        selection: .providers([.codex, .claude]),
        arrangement: .combined,
        visibleProviders: [.grok]
      ) == .automatic
    )
  }

  @Test
  func moreThanOneReadingDrawsIconAndPercentWithoutChangingTheStoredStyle() {
    let specs = MenuBarLabelModel.specs(
      overview: mixedProviders,
      style: .percent,
      provider: .providers([.codex, .claude]),
      arrangement: .separate,
      visibleProviders: [.codex, .claude],
      now: now
    )
    #expect(specs[0].label.icon == .provider(.codex))
    #expect(specs[0].label.text == "68%")
    #expect(
      MenuBarLayout.resolve(
        selection: .providers([.codex, .claude]),
        arrangement: .separate,
        visibleProviders: [.codex, .claude]
      ).effectiveStyle(.icon) == .iconAndPercent
    )
  }

  @Test
  func summaryNamesTheArrangementOnceThereIsMoreThanOneProvider() {
    #expect(
      MenuBarLayout.resolve(
        selection: .automatic,
        arrangement: .separate,
        visibleProviders: [.codex]
      ).settingsSummary == "Automatic"
    )
    #expect(
      MenuBarLayout.resolve(
        selection: .providers([.codex, .claude]),
        arrangement: .combined,
        visibleProviders: [.codex, .claude]
      ).settingsSummary == "Codex, Claude Code · Combined"
    )
    #expect(MenuBarArrangementPreference.fallback == .combined)
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

  /// The item's answer is a function of time — the shared freshness rule retires a reading —
  /// but observation only re-reads it when something it read changed, so the model carries a
  /// clock. It moves exactly when the answer can have moved with it, and not once more.
  @Test @MainActor
  func agingOutMovesTheMenuBarClockAndAnUneventfulMinuteDoesNot() {
    #expect(MenuBarViewModel.menuBarClockInterval == .seconds(60))
    let model = viewModel(
      overview: [item(fingerprint: "codex", windows: [window(id: "weekly", usedPercent: 40)])]
    )

    // What a state update does: new readings are judged against the present.
    model.advanceMenuBarClock(to: now, forNewReadings: true)
    #expect(model.menuBarClock == now)
    #expect(model.menuBarLabel(style: .iconAndPercent, now: model.menuBarClock).text == "60%")

    // A minute in which nothing aged out is a minute the item cannot have changed in, so the
    // status item is not rebuilt for the same answer.
    model.advanceMenuBarClock(to: now.addingTimeInterval(60))
    #expect(model.menuBarClock == now)

    // A day on, the reading no longer describes live quota and the number has to go, with no
    // service event to announce it.
    let agedOut = now.addingTimeInterval(90_000)
    model.advanceMenuBarClock(to: agedOut)
    #expect(model.menuBarClock == agedOut)
    #expect(model.menuBarLabel(style: .iconAndPercent, now: model.menuBarClock).text == nil)
  }

  @Test
  func theStoredStyleKeepsItsWireSpellingAndItsKey() {
    #expect(MenuBarStylePreference.iconAndPercent.rawValue == "icon_and_percent")
    #expect(MenuBarStylePreference.fallback == .iconAndPercent)
    #expect(MenuBarStylePreference.allCases.count == 3)
    #expect(MenuBarStylePreference.storageKey == "menubar.style")
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

  @MainActor
  private func viewModel(overview: [LocalServiceOverviewItem]) -> MenuBarViewModel {
    MenuBarViewModel(
      visualTestState: MenuBarVisualState(
        report: QuotaCollectionReport(capturedAt: now, results: []),
        localUsage: LocalUsageReport(
          generatedAt: now,
          aggregationTimezone: nil,
          range: UsageDateRange(from: "2026-08-01", to: "2026-08-10"),
          status: .unavailable,
          coverage: []
        ),
        accountSummary: nil,
        authStatus: .signedOut,
        overview: overview
      ),
      errorMessage: nil,
      lastCheckedAt: nil
    )
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
      automaticSourceID: source.sourceID,
      automaticSourceDisplayName: source.displayName,
      isStale: isStale
    )
  }
}
