import Foundation
import Testing

@testable import QuotaBar

struct LaunchPresentationTests {
  @Test
  func aLoginLaunchIsSilentAndAManualLaunchOpensThePanelOnlyOnceQuotaHasBeenShown() {
    #expect(
      LaunchPresentation.resolve(loginItem: true, opensWindow: false, hasShownQuota: false)
        == .silent)
    #expect(
      LaunchPresentation.resolve(loginItem: true, opensWindow: true, hasShownQuota: true)
        == .silent)

    #expect(
      LaunchPresentation.resolve(loginItem: false, opensWindow: false, hasShownQuota: false)
        == .mainWindow)
    #expect(
      LaunchPresentation.resolve(loginItem: false, opensWindow: false, hasShownQuota: true)
        == .panel)

    // Open window at launch wins over the panel either way.
    #expect(
      LaunchPresentation.resolve(loginItem: false, opensWindow: true, hasShownQuota: true)
        == .mainWindow)
    #expect(
      LaunchPresentation.resolve(loginItem: false, opensWindow: true, hasShownQuota: false)
        == .mainWindow)
  }
}
