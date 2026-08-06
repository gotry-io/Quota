import AppKit
import Foundation
import Testing

@testable import QuotaBar

@Suite
struct RelaySettingsUITests {
  @Test
  func remoteDeviceRoutesHaveStableTitles() {
    #expect(MenuBarRoute.settings.title == "Settings")
    #expect(MenuBarRoute.agents.title == "Agents")
    #expect(MenuBarRoute.provider(.deepseek).title == "DeepSeek")
    #expect(MenuBarRoute.remoteDevices.title == "Remote Devices")
    #expect(MenuBarRoute.pairDevice.title == "Pair Device")
  }

  @Test
  func customPageStackPushesAndPops() {
    var navigation = MenuBarNavigationState()
    #expect(navigation.currentRoute == nil)
    #expect(navigation.title == "QuotaBar")
    #expect(!navigation.canNavigateBack)

    navigation.open(.settings)
    navigation.open(.agents)
    navigation.open(.provider(.deepseek))
    #expect(navigation.path == [.settings, .agents, .provider(.deepseek)])
    #expect(navigation.title == "DeepSeek")
    #expect(navigation.canNavigateBack)
    #expect(!navigation.showsSettingsMenu)

    navigation.navigateBack()
    #expect(navigation.currentRoute == .agents)
    navigation.navigateBack()

    navigation.open(.remoteDevices)
    navigation.open(.remoteDevices)

    #expect(navigation.path == [.settings, .remoteDevices])
    #expect(navigation.currentRoute == .remoteDevices)
    #expect(navigation.title == "Remote Devices")
    #expect(navigation.canNavigateBack)
    #expect(navigation.showsPairDeviceAction)

    navigation.open(.pairDevice)
    #expect(navigation.path == [.settings, .remoteDevices, .pairDevice])
    #expect(navigation.title == "Pair Device")
    #expect(!navigation.showsPairDeviceAction)

    navigation.navigateBack()
    #expect(navigation.currentRoute == .remoteDevices)
    navigation.navigateBack()
    navigation.navigateBack()
    navigation.navigateBack()
    #expect(navigation.path.isEmpty)
  }

  @Test
  func pairingCodeValidationNormalizesEightCharacterCodes() throws {
    #expect(try RelayPairingCodeValidation.validate("  abcd-efgh  ") == "ABCD-EFGH")
    #expect(try RelayPairingCodeValidation.validate("abcdefgh") == "ABCD-EFGH")
    #expect(RelayPairingCodeValidation.normalize("ab-cd ef_gh") == "ABCDEFGH")
    #expect(RelayPairingCodeValidation.isComplete("ABCD-EFGH"))
    #expect(throws: RelayFormValidationError.missingPairingCode) {
      try RelayPairingCodeValidation.validate("  ")
    }
    #expect(throws: RelayFormValidationError.missingPairingCode) {
      try RelayPairingCodeValidation.validate("ABC")
    }
    #expect(throws: RelayFormValidationError.missingPairingCode) {
      // I and O are outside the Relay alphabet.
      try RelayPairingCodeValidation.validate("ABCDIO12")
    }
  }

  @Test
  func pairCommandStaysVisibleForOtherRelayAndUsesTheValidatedURL() throws {
    let officialURL = try #require(URL(string: "https://quota.gotry.io"))
    let placeholder = RelayPairCommandPresentation.make(
      selectedURL: nil,
      officialURL: officialURL,
      isOtherChoice: true
    )
    #expect(placeholder.command == "quotacli relay pair --relay <relay-url>")
    #expect(!placeholder.canCopy)

    let customURL = try #require(URL(string: "https://relay.example"))
    let custom = RelayPairCommandPresentation.make(
      selectedURL: customURL,
      officialURL: officialURL,
      isOtherChoice: true
    )
    #expect(custom.command == "quotacli relay pair --relay https://relay.example")
    #expect(custom.canCopy)
  }

  @Test
  func errorPresentationNeverEchoesSecrets() {
    let secret = "synthetic_owner_credential_0123456789"
    let leakyError = LeakyError(value: secret)
    let fallback = RelaySettingsErrorPresentation.message(
      for: leakyError,
      fallback: "QuotaBar could not complete pairing."
    )
    #expect(fallback == "QuotaBar could not complete pairing.")
    #expect(fallback?.contains(secret) == false)
  }

  @Test
  func usageTonesMapToSemanticColors() {
    #expect(QuotaUsageTone.tone(remainingPercent: 68) == .healthy)
    #expect(QuotaUsageTone.tone(remainingPercent: 20) == .warning)
    #expect(QuotaUsageTone.tone(remainingPercent: 10) == .critical)
    #expect(QuotaUsageTone.healthy.meterColor == QuotaPalette.accent)
    #expect(QuotaUsageTone.warning.meterColor == QuotaPalette.warning)
    #expect(QuotaUsageTone.critical.meterColor == QuotaPalette.critical)
  }

  @Test
  func primaryButtonTextMeetsAAContrastAcrossSystemAccentsAndAppearances() throws {
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
      let appearance = try #require(NSAppearance(named: appearanceName))
      for color in [NSColor.systemYellow, .systemOrange, .systemIndigo, .systemBlue] {
        let background = QuotaPalette.resolvedColor(color, for: appearance)
        let foreground = QuotaPalette.accessibleTextColor(for: background)
        #expect(
          QuotaPalette.contrastRatio(foreground: foreground, background: background) >= 4.5
        )
      }
    }
  }
}

private struct LeakyError: LocalizedError {
  let value: String
  var errorDescription: String? { value }
}
