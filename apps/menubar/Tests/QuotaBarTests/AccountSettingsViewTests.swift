import Foundation
import QuotaPresentation
import Testing

@testable import QuotaBar

struct AccountSettingsTests {
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
  func mainWindowSidebarListsQuotaUsageAndSettings() {
    #expect(
      MainPage.allCases.map(\.title) == [
        "Quota", "Usage",
        "Account", "Agents", "Notifications", "Menu Bar", "General", "Support",
      ]
    )
    #expect(MainPage.quotaGroup.map(\.title) == ["Quota"])
    #expect(MainPage.usageGroup.map(\.title) == ["Usage"])
    #expect(
      (MainPage.quotaGroup + MainPage.usageGroup).map(\.title) == ["Quota", "Usage"]
    )
    #expect(MainPage.quota.systemImage == "gauge.with.dots.needle.33percent")
    #expect(MainPage.usage.systemImage == "chart.bar")
    #expect(
      MainPage.settingsGroup.map(\.title) == [
        "Account", "Agents", "Notifications", "Menu Bar", "General", "Support",
      ]
    )
  }

  @Test
  func firstOpenMainPageIsQuotaAndTheLastPagePersists() {
    let key = MainPage.storageKey
    let previous = UserDefaults.standard.object(forKey: key)
    defer {
      if let previous {
        UserDefaults.standard.set(previous, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }

    UserDefaults.standard.removeObject(forKey: key)
    #expect(MainPage.resolved == .quota)
    #expect(MainPage.stored == nil)

    UserDefaults.standard.set(MainPage.legacyTodayRawValue, forKey: key)
    #expect(MainPage.resolved == .usage)
    #expect(MainPage.stored == .usage)
    #expect(UserDefaults.standard.string(forKey: key) == MainPage.usage.rawValue)

    UserDefaults.standard.set(MainPage.support.rawValue, forKey: key)
    #expect(MainPage.resolved == .support)
    #expect(MainPage.settingsLandingPage(MainPage.stored) == .support)

    UserDefaults.standard.set(MainPage.quota.rawValue, forKey: key)
    #expect(MainPage.settingsLandingPage(MainPage.stored) == .account)
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
    navigation.open(.provider(.claude))

    #expect(navigation.path == [.provider(.claude)])
    #expect(navigation.title == "Claude Code")
    #expect(navigation.canNavigateBack)

    navigation.navigateBack()
    #expect(navigation.path == [])
    #expect(navigation.currentRoute == nil)
  }

  @Test
  func menuBarSettingsLiveOnTheMainWindowSettingsGroupNotThePanelStack() {
    #expect(MainPage.menuBar.title == "Menu Bar")
    #expect(MainPage.settingsGroup.contains(.menuBar))
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
