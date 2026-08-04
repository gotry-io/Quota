import Foundation
import Testing

@testable import QuotaBar

@Suite
struct RelaySettingsUITests {
  private let profileID = UUID(uuidString: "7A926551-3832-4E39-A931-695563D96541")!

  @Test
  func relayRoutesHaveStableTitles() {
    #expect(MenuBarRoute.settings.title == "Settings")
    #expect(MenuBarRoute.relays.title == "Relays")
    #expect(MenuBarRoute.addRelay.title == "Pair Device")
    #expect(MenuBarRoute.relayDetail(profileID).title == "Relay")
    #expect(MenuBarRoute.pairing(profileID).title == "Pair Device")
    #expect(MenuBarRoute.devices(profileID).title == "Devices")
  }

  @Test
  func customPageStackPushesAndPops() {
    var navigation = MenuBarNavigationState()
    #expect(navigation.currentRoute == nil)
    #expect(navigation.title == "QuotaBar")
    #expect(!navigation.canNavigateBack)

    navigation.open(.settings)
    navigation.open(.relays)
    navigation.open(.relays)

    #expect(navigation.path == [.settings, .relays])
    #expect(navigation.currentRoute == .relays)
    #expect(navigation.title == "Relays")
    #expect(navigation.canNavigateBack)

    navigation.navigateBack()
    #expect(navigation.currentRoute == .settings)
    navigation.navigateBack()
    navigation.navigateBack()
    #expect(navigation.path.isEmpty)
  }

  @Test
  func replaceTurnsTheAddPageIntoTheCreatedRelayDetail() {
    var navigation = MenuBarNavigationState(path: [.settings, .relays, .addRelay])

    navigation.replaceLast(with: .relayDetail(profileID))

    #expect(navigation.path == [.settings, .relays, .relayDetail(profileID)])
    #expect(navigation.currentRoute == .relayDetail(profileID))
  }

  @Test
  func addRelayFormCanonicalizesSafeFieldsWithoutChangingTheCredential() throws {
    let controllerBearer = "synthetic_controller_credential_0123456789"

    let validated = try RelayAddFormValidation.validate(
      name: "  Home Relay  ",
      origin: "HTTPS://Relay.Example:443/",
      controllerBearer: controllerBearer
    )

    #expect(validated.name == "Home Relay")
    #expect(validated.origin == "https://relay.example")
    #expect(validated.controllerBearer == controllerBearer)
  }

  @Test
  func addRelayFormUsesFixedErrorsThatNeverEchoTheCredential() {
    let controllerBearer = "  synthetic_controller_credential_0123456789  "

    do {
      _ = try RelayAddFormValidation.validate(
        name: "Home Relay",
        origin: "https://relay.example",
        controllerBearer: controllerBearer
      )
      Issue.record("Expected credential validation to fail.")
    } catch {
      let message = RelaySettingsErrorPresentation.message(
        for: error,
        fallback: "Check the Relay details and try again."
      )
      #expect(message == "Enter a valid Relay controller credential.")
      #expect(message?.contains(controllerBearer) == false)
    }

    let leakyError = LeakyError(value: controllerBearer)
    let fallback = RelaySettingsErrorPresentation.message(
      for: leakyError,
      fallback: "QuotaBar could not add the Relay."
    )
    #expect(fallback == "QuotaBar could not add the Relay.")
    #expect(fallback?.contains(controllerBearer) == false)
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
  func deviceSequenceLabelHidesTheUnreportedSentinel() throws {
    let response = try QuotaWireCodec.makeDecoder().decode(
      DeviceListResponse.self,
      from: Data(
        #"{"devices":[{"device_id":"device-new","display_name":"New device","created_at":"2026-08-03T10:00:00Z","last_seen_at":null,"last_sequence":-1,"revoked_at":null}]}"#.utf8
      )
    )
    let device = try #require(response.devices.first)

    #expect(device.sequenceLabel == "No reports yet")
  }
}

private struct LeakyError: LocalizedError {
  let value: String
  var errorDescription: String? { value }
}
