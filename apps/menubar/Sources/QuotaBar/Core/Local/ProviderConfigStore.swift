import Foundation

/// Owner-only API-key secrets shared with QuotaCLI (`~/.config/quotacli/providers.json`).
/// Only `ProviderID.configurableCases` may be written; format matches the CLI schema.
@MainActor
struct ProviderConfigStore {
  private let fileURL: URL

  init(fileURL: URL? = nil) {
    if let fileURL {
      self.fileURL = fileURL
    } else {
      self.fileURL = Self.defaultFileURL()
    }
  }

  static func defaultFileURL() -> URL {
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      return URL(fileURLWithPath: xdg, isDirectory: true)
        .appendingPathComponent("quotacli", isDirectory: true)
        .appendingPathComponent("providers.json", isDirectory: false)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("quotacli", isDirectory: true)
      .appendingPathComponent("providers.json", isDirectory: false)
  }

  func status(for provider: ProviderID) -> ProviderApiKeyStatus {
    guard provider.isConfigurable else { return .missing }
    do {
      return status(for: provider, file: try load())
    } catch {
      return .unreadable
    }
  }

  /// One disk read for Agents list (and similar bulk UI).
  func statuses(for providers: [ProviderID]) -> [ProviderID: ProviderApiKeyStatus] {
    let file: ProviderConfigFile
    do {
      file = try load()
    } catch {
      return Dictionary(uniqueKeysWithValues: providers.map { ($0, .unreadable) })
    }
    return Dictionary(uniqueKeysWithValues: providers.map { provider in
      (provider, status(for: provider, file: file))
    })
  }

  /// Saved base URL for form draft (never the API key).
  func baseURL(for provider: ProviderID) -> String? {
    guard provider.isConfigurable else { return nil }
    guard let entry = try? load().providers[provider.rawValue] else { return nil }
    return entry.baseURL
  }

  private func status(for provider: ProviderID, file: ProviderConfigFile) -> ProviderApiKeyStatus {
    guard provider.isConfigurable else { return .missing }
    guard let entry = file.providers[provider.rawValue], !entry.apiKey.isEmpty else {
      return .missing
    }
    return .configured(mask: Self.maskApiKey(entry.apiKey, label: provider.displayName))
  }

  func setApiKey(_ provider: ProviderID, apiKey: String, baseURL: String? = nil) throws {
    guard provider.isConfigurable else {
      throw ProviderConfigStoreError.notConfigurable
    }
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ProviderConfigStoreError.emptyKey
    }
    // Missing file → empty. Corrupt / insecure file → throw (never wipe secrets).
    var file = try load()
    var entry = ProviderSecretEntry(apiKey: trimmed, baseURL: nil)
    if let baseURL {
      let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      if !base.isEmpty {
        entry.baseURL = base
      }
    }
    file.providers[provider.rawValue] = entry
    try save(file)
  }

  func clear(_ provider: ProviderID) throws {
    guard provider.isConfigurable else {
      throw ProviderConfigStoreError.notConfigurable
    }
    var file = try load()
    file.providers[provider.rawValue] = nil
    if file.providers.isEmpty {
      try removeFileIfPresent()
      return
    }
    try save(file)
  }

  /// Update proxy base URL without re-entering the API key (provider must already be configured).
  func updateBaseURL(_ provider: ProviderID, baseURL: String?) throws {
    guard provider.isConfigurable else {
      throw ProviderConfigStoreError.notConfigurable
    }
    var file = try load()
    guard var entry = file.providers[provider.rawValue], !entry.apiKey.isEmpty else {
      throw ProviderConfigStoreError.missingKey
    }
    let trimmed = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    entry.baseURL = trimmed.isEmpty ? nil : trimmed
    file.providers[provider.rawValue] = entry
    try save(file)
  }

  private func load() throws -> ProviderConfigFile {
    let fileManager = FileManager.default
    let path = fileURL.path
    let directory = fileURL.deletingLastPathComponent()

    if fileManager.fileExists(atPath: directory.path) {
      try Self.requireOwnerOnly(path: directory.path, isDirectory: true)
    }

    guard fileManager.fileExists(atPath: path) else {
      return .empty
    }

    try Self.requireOwnerOnly(path: path, isDirectory: false)

    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw ProviderConfigStoreError.unreadable
    }
    if data.isEmpty {
      return .empty
    }
    do {
      return try JSONDecoder().decode(ProviderConfigFile.self, from: data)
    } catch {
      throw ProviderConfigStoreError.invalid
    }
  }

  private func save(_ file: ProviderConfigFile) throws {
    let fileManager = FileManager.default
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path
    )

    let data = try JSONEncoder().encode(file)
    var payload = data
    payload.append(contentsOf: "\n".utf8)
    try payload.write(to: fileURL, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
  }

  private func removeFileIfPresent() throws {
    let path = fileURL.path
    guard FileManager.default.fileExists(atPath: path) else { return }
    try FileManager.default.removeItem(at: fileURL)
  }

  /// Refuse group/other access, matching QuotaCLI `ProviderConfigStore`.
  private static func requireOwnerOnly(path: String, isDirectory: Bool) throws {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: path)
    } catch {
      throw ProviderConfigStoreError.unreadable
    }
    guard let mode = attributes[.posixPermissions] as? NSNumber else {
      throw ProviderConfigStoreError.unreadable
    }
    let permissions = mode.uint16Value
    if (permissions & 0o077) != 0 {
      throw ProviderConfigStoreError.insecurePermissions
    }
    let type = attributes[.type] as? FileAttributeType
    if isDirectory {
      if type != .typeDirectory {
        throw ProviderConfigStoreError.unreadable
      }
    } else if type != .typeRegular {
      throw ProviderConfigStoreError.unreadable
    }
  }

  static func maskApiKey(_ apiKey: String, label: String = "API") -> String {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= 8 {
      return "\(label) key"
    }
    return "\(label) ···\(trimmed.suffix(4))"
  }
}

enum ProviderApiKeyStatus: Equatable {
  case missing
  case unreadable
  case configured(mask: String)
}

enum ProviderConfigStoreError: Error, Equatable {
  case emptyKey
  case missingKey
  case notConfigurable
  case unreadable
  case invalid
  case insecurePermissions
}

private struct ProviderConfigFile: Codable, Equatable {
  var schemaVersion: Int
  var providers: [String: ProviderSecretEntry]

  static let empty = ProviderConfigFile(schemaVersion: 1, providers: [:])

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case providers
  }

  init(schemaVersion: Int, providers: [String: ProviderSecretEntry]) {
    self.schemaVersion = schemaVersion
    self.providers = providers
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    guard schemaVersion == 1 else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Unsupported provider config schema_version."
      )
    }
    let raw = try container.decode([String: ProviderSecretEntry].self, forKey: .providers)
    var validated: [String: ProviderSecretEntry] = [:]
    for (key, entry) in raw {
      guard let provider = ProviderID(rawValue: key), provider.isConfigurable else {
        throw DecodingError.dataCorruptedError(
          forKey: .providers,
          in: container,
          debugDescription: "Unknown or non-configurable provider key."
        )
      }
      let apiKey = entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !apiKey.isEmpty else {
        throw DecodingError.dataCorruptedError(
          forKey: .providers,
          in: container,
          debugDescription: "Empty api_key for \(key)."
        )
      }
      var next = entry
      next.apiKey = apiKey
      if let base = entry.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
        next.baseURL = base
      } else {
        next.baseURL = nil
      }
      validated[provider.rawValue] = next
    }
    providers = validated
  }
}

private struct ProviderSecretEntry: Codable, Equatable {
  var apiKey: String
  var baseURL: String?

  enum CodingKeys: String, CodingKey {
    case apiKey = "api_key"
    case baseURL = "base_url"
  }
}
