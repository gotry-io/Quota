import Foundation
import Testing

@testable import Quota

/// `Quota.storekit` stands in for the App Store products until App Store Connect has them, so it
/// is the thing that has to be right: one subscription group, the two ids the RevenueCat Offering
/// is built from, the durations they are sold for, and the seven-day free trial the paywall
/// promises in words.
///
/// It is read as the declaration it is. Driving it through `SKTestSession` instead would exercise
/// a purchase, but `xcodebuild test` cannot hand the configuration to the simulator's `storekitd`
/// on Xcode 26.3 — every call answers `SKInternalErrorDomain` 3 and no product resolves — so that
/// path is a manual Xcode run, described in `apps/ios/README.md`.
struct StoreKitConfigurationTests {
  @Test
  func oneGroupSellsBothSyncPlansWithASevenDayTrial() throws {
    let configuration = try Self.configuration()
    let groups = try #require(configuration["subscriptionGroups"] as? [[String: Any]])
    #expect(groups.count == 1)
    let group = try #require(groups.first)
    #expect(group["name"] as? String == "Quota Sync")

    let subscriptions = try #require(group["subscriptions"] as? [[String: Any]])
    #expect(
      subscriptions.compactMap { $0["productID"] as? String }
        == SubscriptionTerm.allCases.map(\.productID))

    for subscription in subscriptions {
      let trial = try #require(subscription["introductoryOffer"] as? [String: Any])
      #expect(trial["paymentMode"] as? String == "free")
      #expect(trial["subscriptionPeriod"] as? String == "P1W")
      #expect(trial["numberOfPeriods"] as? Int == 1)
      #expect(subscription["subscriptionGroupID"] as? String == group["id"] as? String)
      #expect(subscription["type"] as? String == "RecurringSubscription")
      #expect(subscription["familyShareable"] as? Bool == false)
    }

    #expect(period(of: subscriptions, term: .monthly) == "P1M")
    #expect(period(of: subscriptions, term: .yearly) == "P1Y")
  }

  /// Nothing is sold outside the Sync group: no one-off products, no non-renewing subscriptions.
  @Test
  func syncIsTheOnlyThingForSale() throws {
    let configuration = try Self.configuration()
    #expect((configuration["products"] as? [Any])?.isEmpty == true)
    #expect((configuration["nonRenewingSubscriptions"] as? [Any])?.isEmpty == true)
  }

  private func period(of subscriptions: [[String: Any]], term: SubscriptionTerm) -> String? {
    subscriptions.first { $0["productID"] as? String == term.productID }?[
      "recurringSubscriptionPeriod"] as? String
  }

  /// The configuration ships as a resource of this bundle rather than of the app, so the app
  /// binary carries no store fixture.
  private static func configuration() throws -> [String: Any] {
    let url = try #require(
      Bundle(for: StoreKitConfigurationMarker.self).url(
        forResource: "Quota",
        withExtension: "storekit"
      )
    )
    return try #require(
      try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
    )
  }
}

private final class StoreKitConfigurationMarker {}
