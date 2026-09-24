import Foundation
import QuotaWidgetProjection
import Testing

@testable import Quota

struct DeepLinkTests {
  @Test
  func oauthCallback() {
    // The end of a browser sign-in that finished outside the session sheet, query and all.
    #expect(
      parse("io.gotry.quota:/oauth/callback?code=abc&state=xyz") == .oauthCallback
    )
    #expect(parse("io.gotry.quota:/oauth/callback") == .oauthCallback)
    #expect(parse("io.gotry.quota:/oauth") == nil)
    #expect(parse("io.gotry.quota:/oauth/callback/extra") == nil)
  }

  /// A subscription link names a `selection_id`: exactly twelve lowercase hex characters once
  /// percent-decoded. Anything else is refused rather than guessed at.
  @Test
  func aSubscriptionLinkIsTwelveLowercaseHexAfterDecoding() {
    #expect(
      parse("io.gotry.quota:/subscriptions/0123456789ab") == .subscription(id: "0123456789ab")
    )
    #expect(
      parse("io.gotry.quota:/subscriptions/0123456789%61b") == .subscription(id: "0123456789ab")
    )
    #expect(
      parse("io.gotry.quota:/subscriptions/%30%31%32%33%34%35%36%37%38%39%61%62")
        == .subscription(id: "0123456789ab")
    )
    #expect(parse("io.gotry.quota:/subscriptions/0123456789AB") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/0123456789%41b") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/0123456789abc") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/0123456789a") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/0123456789ag") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/0123456789-b") == nil)
    #expect(parse("io.gotry.quota:/subscriptions/0123456789_b") == nil)
  }

  @Test
  func rejectsUnknownPathsAndSchemes() {
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
    /// A link that names no detail this phone can open — Overview itself, an id no subscription
    /// answers to, a path Quota does not know — lands on a clean Overview with nothing pending.
    @Test
    func aLinkThatOpensNoDetailLandsOnACleanOverview() {
      for link in [
        "io.gotry.quota:/overview",
        "io.gotry.quota:/subscriptions/0123456789ab",
        "io.gotry.quota:/devices",
      ] {
        let model = AppModel.visualFixture(.content, now: VisualFixture.referenceDate)
        model.selectedTab = .settings
        model.pendingSubscriptionSelection = "0123456789ab"
        model.overviewPath = ["codex|visual_codex|global|"]
        model.openDeepLink(URL(string: link)!)
        #expect(model.selectedTab == .quota, "\(link)")
        #expect(model.pendingSubscriptionSelection == nil, "\(link)")
        #expect(model.overviewPath.isEmpty, "\(link)")
      }
    }

    @Test
    func subscriptionLinkPushesTheMatchingDetail() throws {
      let salt = Data(repeating: 0x5a, count: 32)
      let now = VisualFixture.referenceDate
      let model = AppModel.visualFixture(
        .content,
        now: now,
        selectionSaltStore: InMemorySelectionSaltStore(salt: salt)
      )
      let subscription = try #require(
        model.summary?.subscriptions.first { $0.snapshot.provider == .codex }
      )
      let id = WidgetSnapshotProjection.selectionID(for: subscription, salt: salt)
      model.selectedTab = .usage
      model.openDeepLink(URL(string: "io.gotry.quota:/subscriptions/\(id)")!)
      #expect(model.selectedTab == .quota)
      #expect(model.pendingSubscriptionSelection == nil)
      #expect(model.overviewPath == [subscription.key])
    }

    @Test
    func subscriptionLinkWaitsForSummaryThenResolves() throws {
      let salt = Data(repeating: 0x5a, count: 32)
      let store = InMemorySelectionSaltStore(salt: salt)
      let now = VisualFixture.referenceDate
      let model = AppModel.visualFixture(.signedOut, now: now, selectionSaltStore: store)
      let content = AppModel.visualFixture(.content, now: now, selectionSaltStore: store)
      let subscription = try #require(
        content.summary?.subscriptions.first { $0.snapshot.provider == .codex }
      )
      let id = WidgetSnapshotProjection.selectionID(for: subscription, salt: salt)
      model.openDeepLink(URL(string: "io.gotry.quota:/subscriptions/\(id)")!)
      #expect(model.pendingSubscriptionSelection == id)
      #expect(model.overviewPath.isEmpty)

      VisualScenario.make(.content, now: now).apply(to: model)
      model.resolvePendingSubscriptionSelection()
      #expect(model.pendingSubscriptionSelection == nil)
      #expect(model.overviewPath == [subscription.key])
    }

    @Test
    func logoutClearsTabPendingSelectionAndDetailPath() async {
      let model = AppModel.visualFixture(.content, now: VisualFixture.referenceDate)
      model.selectedTab = .settings
      model.usage.usagePeriod = .today
      model.pendingSubscriptionSelection = "0123456789ab"
      model.overviewPath = ["codex|visual_codex|global|"]
      await model.logout()
      #expect(model.phase == .signedOut)
      #expect(model.selectedTab == .quota)
      #expect(model.usage.usagePeriod == .last30Days)
      #expect(model.pendingSubscriptionSelection == nil)
      #expect(model.overviewPath.isEmpty)
    }
  }
#endif

private func parse(_ string: String) -> DeepLink? {
  DeepLink.parse(URL(string: string)!)
}
