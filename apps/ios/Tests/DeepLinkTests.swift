import Foundation
import Testing

@testable import Quota

struct DeepLinkTests {
  @Test
  func overview() {
    #expect(parse("io.gotry.quota:/overview") == .overview)
  }

  @Test
  func validSubscriptionId() {
    #expect(
      parse("io.gotry.quota:/subscriptions/0123456789ab") == .subscription(id: "0123456789ab")
    )
    #expect(
      parse("io.gotry.quota:/subscriptions/abcdef012345") == .subscription(id: "abcdef012345")
    )
  }

  @Test
  func percentEncodedSelectionIdDecodesThenMatches() {
    #expect(
      parse("io.gotry.quota:/subscriptions/0123456789%61b") == .subscription(id: "0123456789ab")
    )
    #expect(
      parse("io.gotry.quota:/subscriptions/%30%31%32%33%34%35%36%37%38%39%61%62")
        == .subscription(id: "0123456789ab")
    )
  }

  @Test
  func rejectsUppercaseSelectionId() {
    #expect(parse("io.gotry.quota:/subscriptions/0123456789AB") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/0123456789Ab") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/0123456789%41b") == nil)
  }

  @Test
  func rejectsTooLongAndTooShort() {
    #expect(parse("io.gotry.quota:/subscriptions/0123456789abc") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/0123456789a") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/") == nil)
  }

  @Test
  func rejectsIllegalCharacters() {
    #expect(parse("io.gotry.quota:/subscriptions/0123456789zz") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/0123456789ag") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/0123456789-b") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/0123456789_b") == nil)
  }

  @Test
  func rejectsUnknownPathsAndSchemes() {
    #expect(parse("io.gotry.quota:/oauth/callback") == nil)
    #expect(parse("io.gotry.quota:/devices") == nil)
    #expect(parse("io.gotry.quota:/overview/extra") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/0123456789ab/extra") == nil)
    #expect(parse("https://quota.gotry.io/overview") == nil)
    #expect(parse("io.gotry.quota://overview") == nil)
  }

  @Test
  func schemeIsCaseInsensitive() {
    #expect(parse("IO.GOTRY.QUOTA:/overview") == .overview)
  }
}

#if DEBUG
  @MainActor
  struct DeepLinkRoutingTests {
    @Test
    func overviewLinkClearsPendingSelectionAndShowsOverview() {
      let model = AppModel.visualFixture(.content, now: VisualFixture.referenceDate)
      model.selectedTab = .devices
      model.pendingSubscriptionSelection = "0123456789ab"
      model.openDeepLink(URL(string: "io.gotry.quota:/overview")!)
      #expect(model.selectedTab == .overview)
      #expect(model.pendingSubscriptionSelection == nil)
    }

    @Test
    func subscriptionLinkKeepsTheIdAndShowsOverview() {
      let model = AppModel.visualFixture(.content, now: VisualFixture.referenceDate)
      model.selectedTab = .usage
      model.openDeepLink(URL(string: "io.gotry.quota:/subscriptions/0123456789ab")!)
      #expect(model.selectedTab == .overview)
      #expect(model.pendingSubscriptionSelection == "0123456789ab")
    }

    @Test
    func unknownLinkReturnsToOverview() {
      let model = AppModel.visualFixture(.content, now: VisualFixture.referenceDate)
      model.selectedTab = .settings
      model.pendingSubscriptionSelection = "0123456789ab"
      model.openDeepLink(URL(string: "io.gotry.quota:/oauth/callback")!)
      #expect(model.selectedTab == .overview)
      #expect(model.pendingSubscriptionSelection == nil)
    }

    @Test
    func logoutClearsTabAndPendingSelection() async {
      let model = AppModel.visualFixture(.content, now: VisualFixture.referenceDate)
      model.selectedTab = .settings
      model.selectedUsagePeriod = .today
      model.pendingSubscriptionSelection = "0123456789ab"
      await model.logout()
      #expect(model.phase == .signedOut)
      #expect(model.selectedTab == .overview)
      #expect(model.selectedUsagePeriod == .last30Days)
      #expect(model.pendingSubscriptionSelection == nil)
    }
  }
#endif

struct QRCodeImageTests {
  @Test
  func generatesAnImageForTheDownloadURL() {
    #expect(QRCodeImage.make(MacSetupGuideCard.downloadURL.absoluteString) != nil)
  }
}

private func parse(_ string: String) -> DeepLink? {
  DeepLink.parse(URL(string: string)!)
}
