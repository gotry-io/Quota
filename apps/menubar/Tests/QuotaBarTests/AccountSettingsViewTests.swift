import Foundation
import Testing

@testable import QuotaBar

struct AccountSettingsTests {
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
}
