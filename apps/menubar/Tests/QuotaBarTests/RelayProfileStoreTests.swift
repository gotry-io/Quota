import Foundation
import Testing

@testable import QuotaBar

@Suite(.serialized)
struct RelayProfileStoreTests {
  @Test
  func roundTripsProfileMetadataWithoutCredential() throws {
    let fixture = try UserDefaultsFixture()
    defer { fixture.remove() }
    let store = RelayProfileStore(defaults: fixture.defaults)
    let profile = try sampleProfile()

    try store.save([profile])

    let savedData = try #require(
      fixture.defaults.data(forKey: RelayProfileStore.storageKey)
    )
    let savedJSON = try #require(String(data: savedData, encoding: .utf8))
    #expect(!savedJSON.contains("controller_synthetic_secret"))
    #expect(!savedJSON.localizedCaseInsensitiveContains("bearer"))
    #expect(savedJSON.contains(profile.credentialReference))
    #expect(try store.load() == [profile])
  }

  @Test
  func emptyStoreHasNoProfiles() throws {
    let fixture = try UserDefaultsFixture()
    defer { fixture.remove() }

    #expect(try RelayProfileStore(defaults: fixture.defaults).load().isEmpty)
  }

  @Test
  func nonemptyProfilesRequireExactlyOneDefault() throws {
    let fixture = try UserDefaultsFixture()
    defer { fixture.remove() }
    let store = RelayProfileStore(defaults: fixture.defaults)
    let profile = try sampleProfile(isDefault: false)

    #expect(throws: RelayProfileStoreError.invalidData) {
      try store.save([profile])
    }
  }

  @Test(arguments: [
    Data("not json".utf8),
    Data(#"{"schema_version":2,"profiles":[]}"#.utf8),
    Data(#"{"schema_version":1,"profiles":[{"id":"11111111-1111-1111-1111-111111111111"}]}"#.utf8),
    Data(
      #"{"schema_version":1,"profiles":[{"id":"11111111-1111-1111-1111-111111111111","name":"Relay","base_url":"https://relay.example/","instance_id":"relay_primary","mode":"self_hosted","capabilities":{"realtime":false,"persistent_snapshots":true,"instant_device_revocation":true,"history":false,"multi_tenant":false},"credential_reference":"relay-controller:11111111-1111-1111-1111-111111111111","is_default":true}]}"#.utf8
    ),
    Data(
      #"{"schema_version":1,"profiles":[{"id":"11111111-1111-1111-1111-111111111111","name":" Relay ","base_url":"https://relay.example","instance_id":"relay_primary","mode":"self_hosted","capabilities":{"realtime":false,"persistent_snapshots":true,"instant_device_revocation":true,"history":false,"multi_tenant":false},"credential_reference":"relay-controller:11111111-1111-1111-1111-111111111111","is_default":true}]}"#.utf8
    ),
  ])
  func rejectsInvalidProfileData(data: Data) throws {
    let fixture = try UserDefaultsFixture()
    defer { fixture.remove() }
    fixture.defaults.set(data, forKey: RelayProfileStore.storageKey)
    let store = RelayProfileStore(defaults: fixture.defaults)

    do {
      _ = try store.load()
      Issue.record("Expected invalid Relay profile data to fail.")
    } catch let error as RelayProfileStoreError {
      #expect(error == .invalidData)
      #expect(error.errorDescription == "The saved Relay profiles are invalid.")
    }
  }

  @Test
  func profileCanonicalizesAndPermanentlyBindsItsOriginAndCredentialReference() throws {
    let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let profile = try sampleProfile(
      id: id,
      baseURL: URL(string: "HTTPS://Relay.EXAMPLE:443/")!
    )

    #expect(profile.baseURL.absoluteString == "https://relay.example")
    #expect(profile.instanceID == "relay_primary")
    #expect(profile.credentialReference == "relay-controller:11111111-1111-1111-1111-111111111111")
  }
}

private struct UserDefaultsFixture {
  let suiteName: String
  let defaults: UserDefaults

  init() throws {
    suiteName = "QuotaBarTests.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
  }

  func remove() {
    defaults.removePersistentDomain(forName: suiteName)
  }
}

private func sampleProfile(
  id: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
  baseURL: URL = URL(string: "https://relay.example")!,
  isDefault: Bool = true
) throws -> RelayProfile {
  try RelayProfile(
    id: id,
    name: "Primary Relay",
    baseURL: baseURL,
    instanceID: "relay_primary",
    mode: .selfHosted,
    capabilities: RelayCapabilities(
      realtime: false,
      persistentSnapshots: true,
      instantDeviceRevocation: true,
      history: false,
      multiTenant: false
    ),
    isDefault: isDefault
  )
}
