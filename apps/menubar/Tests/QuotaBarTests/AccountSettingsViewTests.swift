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
