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
    #expect(MenuBarRoute.addRelay.title == "Add Relay")
    #expect(MenuBarRoute.relayDetail(profileID).title == "Relay")
    #expect(MenuBarRoute.pairing(profileID).title == "Pair device")
    #expect(MenuBarRoute.devices(profileID).title == "Devices")
  }

  @Test
  func navigationCallbacksUseOneTypedPathAndReturnToRelaysAfterDeletion() {
    var navigation = MenuBarNavigationState()

    navigation.open(.settings)
    navigation.open(.relays)
    navigation.open(.relayDetail(profileID))
    navigation.open(.pairing(profileID))
    #expect(navigation.path == [
      .settings, .relays, .relayDetail(profileID), .pairing(profileID),
    ])
    #expect(navigation.title == "Pair device")
    #expect(navigation.canNavigateBack)

    navigation.navigateBack()
    #expect(navigation.path.last == .relayDetail(profileID))

    navigation.finishDeletingRelay(profileID)
    #expect(navigation.path == [.settings, .relays])
    #expect(navigation.title == "Relays")

    navigation.open(.addRelay)
    navigation.replaceLast(with: .relayDetail(profileID))
    #expect(navigation.path == [.settings, .relays, .relayDetail(profileID)])
  }

  @Test
  func deletingAnUnrelatedRelayDoesNotRemoveTheCurrentDetail() {
    let otherID = UUID(uuidString: "20806B70-D9D6-4F27-BDB9-2740E2380E3A")!
    var navigation = MenuBarNavigationState(
      path: [.settings, .relays, .relayDetail(profileID)]
    )

    navigation.finishDeletingRelay(otherID)

    #expect(navigation.path == [.settings, .relays, .relayDetail(profileID)])
  }

  @Test
  func addRelayFormCanonicalizesSafeFieldsWithoutChangingTheCredential() throws {
    let ownerBearer = "synthetic_owner_credential_0123456789"

    let validated = try RelayAddFormValidation.validate(
      name: "  Home Relay  ",
      origin: "HTTPS://Relay.Example:443/",
      ownerBearer: ownerBearer
    )

    #expect(validated.name == "Home Relay")
    #expect(validated.origin == "https://relay.example")
    #expect(validated.ownerBearer == ownerBearer)
  }

  @Test
  func addRelayFormUsesFixedErrorsThatNeverEchoTheCredential() {
    let ownerBearer = "  synthetic_owner_credential_0123456789  "

    do {
      _ = try RelayAddFormValidation.validate(
        name: "Home Relay",
        origin: "https://relay.example",
        ownerBearer: ownerBearer
      )
      Issue.record("Expected credential validation to fail.")
    } catch {
      let message = RelaySettingsErrorPresentation.message(
        for: error,
        fallback: "Check the Relay details and try again."
      )
      #expect(message == "Enter a valid Relay owner credential.")
      #expect(message?.contains(ownerBearer) == false)
    }

    let leakyError = LeakyError(value: ownerBearer)
    let fallback = RelaySettingsErrorPresentation.message(
      for: leakyError,
      fallback: "QuotaBar could not add the Relay."
    )
    #expect(fallback == "QuotaBar could not add the Relay.")
    #expect(fallback?.contains(ownerBearer) == false)
  }

  @Test
  func pairingCodeValidationTrimsInputAndRejectsEmptyValues() throws {
    #expect(try RelayPairingCodeValidation.validate("  ABCD-EFGH  ") == "ABCD-EFGH")
    #expect(throws: RelayFormValidationError.missingPairingCode) {
      try RelayPairingCodeValidation.validate("  ")
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
