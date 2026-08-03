import Foundation

enum RelayProfileStoreError: LocalizedError, Equatable, Sendable {
  case invalidData
  case couldNotSave

  var errorDescription: String? {
    switch self {
    case .invalidData:
      "The saved Relay profiles are invalid."
    case .couldNotSave:
      "QuotaBar could not save the Relay profiles."
    }
  }
}

struct RelayProfileStore {
  static let storageKey = "io.gotry.quotabar.relay-profiles"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() throws -> [RelayProfile] {
    guard let data = defaults.data(forKey: Self.storageKey) else {
      return []
    }

    do {
      let payload = try QuotaWireCodec.makeDecoder().decode(
        RelayProfilePayload.self,
        from: data
      )
      try validate(payload.profiles)
      return payload.profiles
    } catch {
      throw RelayProfileStoreError.invalidData
    }
  }

  func save(_ profiles: [RelayProfile]) throws {
    do {
      try validate(profiles)
      let data = try QuotaWireCodec.makeEncoder().encode(
        RelayProfilePayload(schemaVersion: 1, profiles: profiles)
      )
      defaults.set(data, forKey: Self.storageKey)
    } catch let error as RelayProfileStoreError {
      throw error
    } catch {
      throw RelayProfileStoreError.couldNotSave
    }
  }

  private func validate(_ profiles: [RelayProfile]) throws {
    guard Set(profiles.map(\.id)).count == profiles.count,
      Set(profiles.map(\.credentialReference)).count == profiles.count,
      profiles.filter(\.isDefault).count == (profiles.isEmpty ? 0 : 1)
    else {
      throw RelayProfileStoreError.invalidData
    }

    for profile in profiles {
      let canonicalURL = try RelayOrigin.canonicalURL(from: profile.baseURL)
      let canonicalName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard canonicalURL == profile.baseURL,
        profile.credentialReference == RelayProfile.credentialReference(for: profile.id),
        !canonicalName.isEmpty,
        canonicalName == profile.name,
        !profile.instanceID.isEmpty,
        profile.capabilities.persistentSnapshots,
        profile.capabilities.instantDeviceRevocation
      else {
        throw RelayProfileStoreError.invalidData
      }
    }
  }
}

private struct RelayProfilePayload: Codable {
  let schemaVersion: Int
  let profiles: [RelayProfile]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case profiles
  }

  init(schemaVersion: Int, profiles: [RelayProfile]) {
    self.schemaVersion = schemaVersion
    self.profiles = profiles
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    profiles = try container.decode([RelayProfile].self, forKey: .profiles)
    guard schemaVersion == 1 else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Unsupported Relay profile schema version."
      )
    }
  }
}
