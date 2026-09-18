import Foundation
import Testing

@testable import QuotaBar

struct LaunchPresentationTests {
  @Test
  func loginItemLaunchIsSilent() {
    #expect(
      LaunchPresentation.resolve(loginItem: true, opensWindow: false, hasShownQuota: false)
        == .silent)
    #expect(
      LaunchPresentation.resolve(loginItem: true, opensWindow: true, hasShownQuota: true)
        == .silent)
  }

  @Test
  func manualLaunchOpensTheWindowUntilQuotaHasBeenShown() {
    #expect(
      LaunchPresentation.resolve(loginItem: false, opensWindow: false, hasShownQuota: false)
        == .mainWindow)
  }

  @Test
  func manualLaunchOpensThePanelOnceQuotaHasBeenShown() {
    #expect(
      LaunchPresentation.resolve(loginItem: false, opensWindow: false, hasShownQuota: true)
        == .panel)
  }

  @Test
  func openWindowAtLaunchShowsTheWindow() {
    #expect(
      LaunchPresentation.resolve(loginItem: false, opensWindow: true, hasShownQuota: true)
        == .mainWindow)
    #expect(
      LaunchPresentation.resolve(loginItem: false, opensWindow: true, hasShownQuota: false)
        == .mainWindow)
  }

  @Test
  func launchWindowPreferenceReadsAStoredValueAndFallsBackWhenUntouched() {
    let key = LaunchWindowPreference.storageKey
    let previous = UserDefaults.standard.object(forKey: key)
    defer {
      if let previous {
        UserDefaults.standard.set(previous, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }

    UserDefaults.standard.removeObject(forKey: key)
    #expect(!LaunchWindowPreference.fallback)
    #expect(!LaunchWindowPreference.isOn)

    UserDefaults.standard.set(true, forKey: key)
    #expect(LaunchWindowPreference.isOn)

    UserDefaults.standard.set(false, forKey: key)
    #expect(!LaunchWindowPreference.isOn)
  }
}
