import Testing

@testable import QuotaBar

@Test func menuBarPresenceSaysNothingUntilTheBarHasPlacedAnItem() {
  #expect(MenuBarPresenceCopy.sentence(onScreen: nil) == nil)
}

@Test func menuBarPresenceNamesWhatToCheckWhenTheItemIsOffScreen() {
  #expect(MenuBarPresenceCopy.sentence(onScreen: true) == "Shown.")
  let off = MenuBarPresenceCopy.sentence(onScreen: false) ?? ""
  #expect(off.contains("System Settings"))
  #expect(off.contains("Menu Bar"))
}

@Test @MainActor func theModelKeepsTheLastPresenceItWasTold() {
  let model = MenuBarViewModel(visualTestState: nil, errorMessage: nil, lastCheckedAt: nil)
  #expect(model.menuBarItemOnScreen == nil)
  model.noteMenuBarItemPresence(onScreen: false)
  #expect(model.menuBarItemOnScreen == false)
  model.noteMenuBarItemPresence(onScreen: true)
  #expect(model.menuBarItemOnScreen == true)
}
