import Foundation
import Testing

@testable import QuotaBar

@MainActor
struct AgentsSettingsViewTests {
  @Test
  func sidebarBadgeNamesHowManyAreShownAndWhoNeedsSignIn() throws {
    let shownKey = SettingsPage.storageKey
    let previousPage = UserDefaults.standard.object(forKey: shownKey)
    defer {
      if let previousPage {
        UserDefaults.standard.set(previousPage, forKey: shownKey)
      } else {
        UserDefaults.standard.removeObject(forKey: shownKey)
      }
    }

    let content = try #require(
      VisualTestConfiguration(arguments: ["QuotaBar", "--fixture", "content"])
    )
    content.prepareEnvironment()
    #expect(content.makeModel().agentsSidebarBadge() == "3 shown")

    let signedOut = try #require(
      VisualTestConfiguration(arguments: ["QuotaBar", "--fixture", "empty"])
    )
    signedOut.prepareEnvironment()
    #expect(signedOut.makeModel().agentsSidebarBadge() == "3 shown · 3 need sign-in")
  }

  @Test
  func reorderTargetUsesHysteresisAroundRowBoundary() {
    let rowHeight = QuotaDesign.Layout.settingsRowHeight

    #expect(
      AgentsSettingsView.reorderTargetIndex(
        originIndex: 1,
        currentIndex: 1,
        translation: rowHeight * 0.61,
        count: 3
      ) == 2
    )
    #expect(
      AgentsSettingsView.reorderTargetIndex(
        originIndex: 1,
        currentIndex: 2,
        translation: rowHeight * 0.55,
        count: 3
      ) == 2
    )
    #expect(
      AgentsSettingsView.reorderTargetIndex(
        originIndex: 1,
        currentIndex: 2,
        translation: rowHeight * 0.39,
        count: 3
      ) == 1
    )
  }

  @Test
  func reorderTargetCanCrossMultipleRowsInOneUpdate() {
    #expect(
      AgentsSettingsView.reorderTargetIndex(
        originIndex: 3,
        currentIndex: 3,
        translation: -QuotaDesign.Layout.settingsRowHeight * 3,
        count: 4
      ) == 0
    )
  }
}
