import Testing

@testable import QuotaBar

@Test func menuBarPresenceSaysNothingUntilTheBarHasPlacedAnItem() {
  #expect(MenuBarPresenceCopy.sentence(onScreen: nil) == nil)
}
