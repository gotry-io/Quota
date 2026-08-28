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
    #expect(MenuBarStylePreference.allCases.map(\.label) == ["Icon", "Percent", "Icon and percent"])

    let choices = MenuBarProviderPreference.choices(visibleProviders: [.grok, .codex, .claude])
    #expect(choices.first == .automatic)
    #expect(choices.map(\.label) == ["Automatic", "Grok", "Codex", "Claude Code"])
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
