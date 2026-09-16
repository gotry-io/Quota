import QuotaWire
import Testing

@testable import QuotaBar

struct MenuBarSettingsFormTests {
  @Test
  func theFormsCombinedControlIsDisabledWhenFourProvidersAreNamed() {
    let four: [ProviderID] = [.codex, .claude, .grok, .cursor]
    let layout = MenuBarLayout.resolve(
      selection: .providers(four),
      arrangement: .combined,
      visibleProviders: four
    )

    #expect(layout.showsArrangementControl)
    #expect(!layout.isCombinedEnabled)
    #expect(layout == .items(four))
    #expect(layout.effectiveArrangement == .separate)
  }

  @Test
  func combinedStaysAvailableForTwoOrThreeNamedProviders() {
    let three: [ProviderID] = [.codex, .claude, .grok]
    let packed = MenuBarLayout.resolve(
      selection: .providers(three),
      arrangement: .combined,
      visibleProviders: three
    )
    #expect(packed.showsArrangementControl)
    #expect(packed.isCombinedEnabled)
    #expect(packed == .packed(three))

    let two = MenuBarLayout.resolve(
      selection: .providers([.codex, .claude]),
      arrangement: .separate,
      visibleProviders: three
    )
    #expect(two.showsArrangementControl)
    #expect(two.isCombinedEnabled)
    #expect(two.effectiveArrangement == .separate)
  }

  @Test
  func turningAutomaticOffNamesEveryOverviewProvider() {
    let visible: [ProviderID] = [.grok, .codex, .claude]
    let named = MenuBarProviderPreference.automatic.turningAutomaticOff(
      visibleProviders: visible
    )
    #expect(named.selected == visible)
    #expect(!named.isAutomatic)

    let alreadyNamed = MenuBarProviderPreference.provider(.codex).turningAutomaticOff(
      visibleProviders: visible
    )
    #expect(alreadyNamed == .provider(.codex))
  }

  @Test
  func stylePickerIsAMenuBecauseThereAreFiveStyles() {
    #expect(MenuBarStylePreference.allCases.count == 5)
    #expect(!MenuBarStylePreference.usesSegmentedPicker)
  }
}
