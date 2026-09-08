import Foundation
import QuotaPresentation
import Testing

@testable import QuotaBar

struct AccountSettingsPageTests {
  @Test
  func signedInAccountPageHoldsEverythingThatBelongsToTheAccount() {
    #expect(
      AccountSettingsItem.items(for: .signedIn) == [
        .identity, .syncUsage, .devices, .website, .signOut,
      ]
    )
  }

  @Test
  func anAccountNobodyIsSignedInToHasNothingToManage() {
    for state in [AccountViewState.signedOut, .notChecked, .logoutPending] {
      #expect(AccountSettingsItem.items(for: state).isEmpty)
    }
  }

  @Test
  func aProviderSourceIsOneLevelBelowTheAgentPage() {
    var navigation = MenuBarNavigationState()
    navigation.open([
      .settings, .agents, .provider(.codex),
      .providerSource(
        .codex, identityKey: "codex|fp|global|", sourceID: "local", displayName: "This Mac"),
    ])
    #expect(navigation.title == "This Mac")
    navigation.navigateBack()
    #expect(navigation.path == [.settings, .agents, .provider(.codex)])
  }

  @Test
  func overviewOpensAProviderThroughSettingsAndAgentsInOneStep() {
    var navigation = MenuBarNavigationState()
    navigation.open([.settings, .agents, .provider(.codex)])

    #expect(navigation.path == [.settings, .agents, .provider(.codex)])
    #expect(navigation.title == "Codex")

    navigation.navigateBack()
    #expect(navigation.path == [.settings, .agents])
    #expect(navigation.title == "Agents")
  }

  @Test
  func accountIsOneLevelBelowSettingsAndDevicesOneLevelBelowThat() {
    var navigation = MenuBarNavigationState()
    navigation.open(.settings)
    navigation.open(.account)
    navigation.open(.devices)

    #expect(navigation.path == [.settings, .account, .devices])
    #expect(navigation.title == "Devices")
    #expect(MenuBarRoute.account.title == "Account")
  }

  @Test
  func notificationsIsOneLevelBelowSettings() {
    var navigation = MenuBarNavigationState()
    navigation.open(.settings)
    navigation.open(.notifications)

    #expect(navigation.path == [.settings, .notifications])
    #expect(navigation.title == "Notifications")
    #expect(MenuBarRoute.notifications.title == "Notifications")

    navigation.navigateBack()
    #expect(navigation.path == [.settings])
  }

  @Test
  func chosingAMenuBarOptionIsOneLevelDownAndReturnsWhenItIsChosen() {
    var navigation = MenuBarNavigationState()
    navigation.open(.settings)
    navigation.open(.menuBarStyle)

    #expect(navigation.path == [.settings, .menuBarStyle])
    #expect(navigation.title == "Menu Bar Style")

    // Style choosing takes effect and returns; there is nothing else on the page to confirm.
    navigation.navigateBack()
    #expect(navigation.path == [.settings])

    navigation.open(.menuBarProvider)
    #expect(navigation.title == "Menu Bar Provider")
    // Provider is a set of toggles, so the page stays until Back.
    navigation.navigateBack()
    #expect(navigation.path == [.settings])
  }

  @Test
  func theStylePageOffersEveryStyleAndTheProviderPageOverviewsOwnOrder() {
    #expect(
      MenuBarStylePreference.allCases.map(\.label)
        == [
          "Icon",
          "Percent",
          "Icon and percent",
          "Icon and today cost",
          "Icon and today tokens",
        ]
    )

    let choices = MenuBarProviderPreference.choices(visibleProviders: [.grok, .codex, .claude])
    #expect(choices.first == .automatic)
    #expect(choices.map(\.label) == ["Automatic", "Grok", "Codex", "Claude Code"])
  }

  @Test
  func usagePeriodTabsUseTheSharedPeriodNames() {
    let segments = UsagePeriodSegment.allCases.filter { $0 != .custom }
    #expect(segments.map(\.title) == ["Day", "Week", "Month", "7D", "30D", "All"])
    #expect(
      segments.map(\.accessibilityTitle)
        == ["Today", "This week", "This month", "Last 7 days", "Last 30 days", "All"]
    )
    // Only the four the summary already folds are read out of `get_state`.
    #expect(UsagePeriodSelection.today.summaryKey == .today)
    #expect(UsagePeriodSelection.thisMonth.summaryKey == nil)
  }

  @Test
  func signingOutClosesTheAccountPageAndWhateverWasOpenedFromIt() {
    var navigation = MenuBarNavigationState()
    navigation.open(.settings)
    navigation.open(.account)
    navigation.open(.devices)

    #expect(navigation.closing(.account)?.path == [.settings])
    // A person who never opened Account is left exactly where they are.
    #expect(MenuBarNavigationState(path: [.settings, .usage]).closing(.account) == nil)
  }
}

/// Sync is free for every account, so the only thing standing between this Mac's Usage and
/// the account is being signed in to one.
@MainActor
struct SyncAccountStateTests {
  @Test
  func aSignedInAccountUploadsWithoutAnythingToBuy() async {
    let model = MenuBarViewModel(
      client: StubLocalService(state: justSignedInState(label: "octocat"))
    )
    await model.refreshIfNeeded()

    #expect(model.accountState == .signedIn)
    #expect(model.syncUsageDisabledReason == nil)
  }

  @Test
  func aSignedOutMacIsToldToSignInRatherThanToPay() async {
    let model = MenuBarViewModel(
      client: StubLocalService(state: signedOutWithSessionEndedState())
    )
    await model.refreshIfNeeded()

    #expect(model.accountState != .signedIn)
    #expect(model.syncUsageDisabledReason == "Sign in to your Quota account")
    #expect(AccountSettingsItem.items(for: model.accountState).isEmpty)
  }
}
