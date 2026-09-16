import Foundation
import QuotaPresentation
import Testing

@testable import QuotaBar

struct AccountSettingsPageTests {
  @Test
  func signedInAccountPageHoldsIdentityDevicesWebsiteAndSignOut() {
    #expect(
      AccountSettingsItem.items(for: .signedIn) == [
        .identity, .devices, .website, .signOut,
      ]
    )
  }

  @Test
  func anAccountNobodyIsSignedInToHasNothingToManageOnTheSignedInList() {
    for state in [AccountViewState.signedOut, .notChecked, .logoutPending] {
      #expect(AccountSettingsItem.items(for: state).isEmpty)
    }
  }

  @Test
  func settingsWindowSidebarListsTheSixPages() {
    #expect(
      SettingsPage.allCases.map(\.title) == [
        "Account", "Agents", "Notifications", "Menu Bar", "General", "Support",
      ]
    )
  }

  @Test
  func overviewOpensAProviderAsAReadOnlyDetail() {
    var navigation = MenuBarNavigationState()
    navigation.open(.provider(.codex))

    #expect(navigation.path == [.provider(.codex)])
    #expect(navigation.title == "Codex")

    navigation.navigateBack()
    #expect(navigation.path == [])
  }

  @Test
  func panelNavigationStaysZeroOrOneDeep() {
    var navigation = MenuBarNavigationState()
    navigation.open(.provider(.codex))
    navigation.open(.usage)

    #expect(navigation.path == [.usage])
    #expect(navigation.title == "Usage")
    #expect(navigation.canNavigateBack)

    navigation.navigateBack()
    #expect(navigation.path == [])
    #expect(navigation.currentRoute == nil)
  }

  @Test
  func menuBarSettingsLiveOnTheSettingsWindowPageNotThePanelStack() {
    #expect(SettingsPage.menuBar.title == "Menu Bar")
    #expect(SettingsPage.allCases.contains(.menuBar))
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
  func devicesLiveOnTheAccountPageAndRemoveOpensTheWebDevicesPage() {
    #expect(AccountDevicesCopy.thisMac == "This Mac")
    #expect(AccountDevicesCopy.remove == "Remove")
    #expect(AccountDevicesCopy.removeTitle("Studio Mac") == "Remove Studio Mac?")
    #expect(AccountDevicesCopy.removeMessage.contains("quota.gotry.io"))
    #expect(AppMetadata.devicesURL.absoluteString == "https://quota.gotry.io/my/devices")
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

  @Test
  func thisMacDeviceIdComesFromTheAccountState() async {
    let model = MenuBarViewModel(
      client: StubLocalService(state: justSignedInState(label: "octocat"))
    )
    await model.refreshIfNeeded()
    #expect(model.accountDeviceID == "device_1")
  }
}
