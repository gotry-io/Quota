import Foundation
import Testing

@testable import QuotaBar

struct QuotaBarDeepLinkTests {
  @Test
  func parsesTheTwoPathsADesktopWidgetCanLinkTo() {
    #expect(QuotaBarDeepLink.parse(URL(string: "quotabar:/overview")!) == .overview)
    #expect(
      QuotaBarDeepLink.parse(URL(string: "quotabar:/subscriptions/0123456789ab")!)
        == .subscription(id: "0123456789ab")
    )
    #expect(QuotaBarDeepLink.parse(URL(string: "QuotaBar:/overview")!) == .overview)
  }

  @Test
  func refusesAnythingElse() {
    // Quota on iPhone answers its own scheme; a Mac widget's link is never that one.
    #expect(QuotaBarDeepLink.parse(URL(string: "io.gotry.quota:/overview")!) == nil)
    #expect(QuotaBarDeepLink.parse(URL(string: "quotabar://host/overview")!) == nil)
    #expect(QuotaBarDeepLink.parse(URL(string: "quotabar:/subscriptions")!) == nil)
    #expect(QuotaBarDeepLink.parse(URL(string: "quotabar:/subscriptions/ABCDEF012345")!) == nil)
    #expect(QuotaBarDeepLink.parse(URL(string: "quotabar:/subscriptions/0123456789")!) == nil)
    #expect(QuotaBarDeepLink.parse(URL(string: "quotabar:/settings")!) == nil)
  }
}
