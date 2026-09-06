import Foundation
import Testing

@testable import QuotaBar

struct AccountSettingsPageTests {
  @Test
  func signedInAccountPageHoldsEverythingThatBelongsToTheAccount() {
    #expect(
      AccountSettingsItem.items(for: .signedIn) == [
        .identity, .sync, .syncUsage, .devices, .website, .signOut,
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
    #expect(MenuBarStylePreference.allCases.map(\.label) == ["Icon", "Percent", "Icon and percent"])

    let choices = MenuBarProviderPreference.choices(visibleProviders: [.grok, .codex, .claude])
    #expect(choices.first == .automatic)
    #expect(choices.map(\.label) == ["Automatic", "Grok", "Codex", "Claude Code"])
  }

  @Test
  func usagePeriodTabsUseTheSharedPeriodNames() {
    #expect(UsagePeriod.allCases.map(\.label) == ["Today", "7 Days", "30 Days", "2 Years"])
    #expect(
      UsagePeriod.allCases.map(\.accessibilityLabel)
        == ["Today", "7 Days", "30 Days", "Up to 2 years"]
    )
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

/// What the Account page says about the subscription sync is paid for.
///
/// Three states, one line each, and the words the website uses for the same entitlement.
struct SyncStatusCopyTests {
  private let utc = TimeZone(identifier: "UTC")!
  private let expiresAt = Date(timeIntervalSince1970: 1_791_158_400)  // 2026-10-05T00:00:00Z
  private let checkedAt = Date(timeIntervalSince1970: 1_788_602_400)  // 2026-09-05T10:00:00Z
  private let now = Date(timeIntervalSince1970: 1_788_609_600)  // 2026-09-05T12:00:00Z

  private func entitlement(
    _ status: LocalServiceEntitlementStatus,
    willRenew: Bool = true,
    stale: Bool = false,
    expires: Bool = true
  ) -> LocalServiceEntitlement {
    LocalServiceEntitlement(
      status: status,
      expiresAt: expires ? expiresAt : nil,
      willRenew: willRenew,
      stale: stale,
      checkedAt: checkedAt
    )
  }

  @Test
  func aPaidAccountSaysWhenItRenewsOrEnds() {
    #expect(
      SyncStatusCopy.status(entitlement(.active), now: now, timeZone: utc)
        == "Active · renews Oct 5"
    )
    #expect(
      SyncStatusCopy.status(entitlement(.active, willRenew: false), now: now, timeZone: utc)
        == "Active · ends Oct 5"
    )
    #expect(SyncStatusCopy.action(entitlement(.active)) == "Manage…")
  }

  @Test
  func aBillingProblemIsSaidAsOneAndStillSyncs() {
    let grace = entitlement(.grace)
    #expect(
      SyncStatusCopy.status(grace, now: now, timeZone: utc)
        == "Grace period · update payment"
    )
    #expect(grace.allowsSync)
    #expect(SyncStatusCopy.action(grace) == "Manage…")
  }

  @Test
  func anAccountThatDoesNotPaySaysSoAndIsOfferedTheWayToStart() {
    for status in [LocalServiceEntitlementStatus.expired, .none, .unknown] {
      let value = entitlement(status, willRenew: false)
      #expect(SyncStatusCopy.status(value, now: now, timeZone: utc) == "Not subscribed")
      #expect(!value.allowsSync)
      #expect(SyncStatusCopy.action(value) == "Subscribe…")
    }
  }

  /// A stale answer is old values, so it spends the line on how old it is rather than on a
  /// renewal date nobody could confirm.
  @Test
  func aStaleAnswerNamesWhenItWasLastCheckedInsteadOfWhenItRenews() {
    #expect(
      SyncStatusCopy.status(entitlement(.active, stale: true), now: now, timeZone: utc)
        == "Active · checked 2h ago"
    )
    #expect(
      SyncStatusCopy.status(entitlement(.grace, stale: true), now: now, timeZone: utc)
        == "Grace period · checked 2h ago"
    )
    // Nothing read yet is not the same as nothing bought.
    #expect(SyncStatusCopy.status(nil, now: now, timeZone: utc) == "Checking…")
  }
}

@MainActor
struct SyncAccountStateTests {
  private let expiresAt = Date(timeIntervalSince1970: 1_791_158_400)
  private let purchaseURL = URL(string: "https://pay.rev.cat/testtoken/account_1")!

  private func model(_ entitlement: LocalServiceEntitlement?) async -> MenuBarViewModel {
    let model = MenuBarViewModel(
      client: StubLocalService(
        state: justSignedInState(
          label: "octocat",
          entitlement: entitlement,
          purchaseURL: purchaseURL
        )
      )
    )
    await model.refreshIfNeeded()
    return model
  }

  @Test
  func aPaidAccountManagesItsSubscriptionAndUploads() async {
    let model = await model(
      LocalServiceEntitlement(
        status: .active, expiresAt: expiresAt, willRenew: true, stale: false, checkedAt: nil
      )
    )

    #expect(model.syncIsPaid)
    #expect(model.syncActionLabel == "Manage…")
    #expect(model.syncActionURL == AppMetadata.manageSubscriptionURL)
    #expect(model.syncUsageDisabledReason == nil)
  }

  @Test
  func anUnpaidAccountIsSentToTheAccountsOwnPurchaseLinkAndCannotUpload() async {
    let model = await model(
      LocalServiceEntitlement(
        status: .none, expiresAt: nil, willRenew: false, stale: false, checkedAt: nil
      )
    )

    #expect(!model.syncIsPaid)
    #expect(model.syncStatusLabel == "Not subscribed")
    #expect(model.syncActionLabel == "Subscribe…")
    #expect(model.syncActionURL == purchaseURL)
    #expect(model.syncUsageDisabledReason == "Needs a subscription")
  }

  /// Before the first account read there is no entitlement to state, and Sync Usage is not
  /// taken away from a Mac on the strength of an answer nobody has yet.
  @Test
  func anAccountThatHasNotBeenReadYetIsNotCalledUnsubscribed() async {
    let model = await model(nil)

    #expect(!model.syncIsPaid)
    #expect(model.syncStatusLabel == "Checking…")
    #expect(model.syncUsageDisabledReason == nil)
  }
}
