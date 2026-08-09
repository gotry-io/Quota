import Darwin
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
    guard provider.isConfigurable, provider.supportsBaseURL else { return nil }
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
    let suppliedBase = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !provider.supportsBaseURL && !suppliedBase.isEmpty {
      throw ProviderConfigStoreError.invalidBaseURL
    }
    let normalizedBase = try Self.validatedBaseURL(
      provider.supportsBaseURL ? baseURL : nil,
      for: provider
    )
    // Missing file → empty. Corrupt / insecure file → throw (never wipe secrets).
    try withWriteLock {
      var file = try load()
      file.providers[provider.rawValue] = ProviderSecretEntry(
        apiKey: trimmed,
        baseURL: normalizedBase
      )
      try save(file)
    }
  }

  func clear(_ provider: ProviderID) throws {
    guard provider.isConfigurable else {
      throw ProviderConfigStoreError.notConfigurable
    }
    try withWriteLock {
      var file = try load()
      file.providers[provider.rawValue] = nil
      if file.providers.isEmpty {
        try removeFileIfPresent()
        return
      }
      try save(file)
    }
  }

  /// Update proxy base URL without re-entering the API key (provider must already be configured).
  func updateBaseURL(_ provider: ProviderID, baseURL: String?) throws {
    guard provider.isConfigurable else {
      throw ProviderConfigStoreError.notConfigurable
    }
    try withWriteLock {
      var file = try load()
      guard var entry = file.providers[provider.rawValue], !entry.apiKey.isEmpty else {
        throw ProviderConfigStoreError.missingKey
      }
      guard provider.supportsBaseURL else {
        throw ProviderConfigStoreError.invalidBaseURL
      }
      entry.baseURL = try Self.validatedBaseURL(baseURL, for: provider)
      file.providers[provider.rawValue] = entry
      try save(file)
    }
  }

  /// Aligns with CLI `normalizeBaseUrl` (HTTPS origin; optional private HTTP).
  static func normalizeBaseURL(
    _ value: String?,
    allowPrivateHttp: Bool
  ) -> String? {
    guard var trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else {
      return nil
    }
    while trimmed.hasSuffix("/") {
      trimmed.removeLast()
    }
    guard !trimmed.isEmpty else { return nil }

    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: candidate),
      let scheme = url.scheme?.lowercased(),
      let host = url.host,
      !host.isEmpty
    else {
      return nil
    }
    if url.user != nil || url.password != nil {
      return nil
    }

    let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
    switch scheme {
    case "https":
      let origin = "https://\(host)\(url.port.map { ":\($0)" } ?? "")"
      return path.isEmpty ? origin : "\(origin)\(path)"
    case "http" where allowPrivateHttp && isPrivateOrLocalHost(host):
      let origin = "http://\(host)\(url.port.map { ":\($0)" } ?? "")"
      return path.isEmpty ? origin : "\(origin)\(path)"
    default:
      return nil
    }
  }

  private static func validatedBaseURL(_ value: String?, for provider: ProviderID) throws -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
      if provider.requiresBaseURL {
        throw ProviderConfigStoreError.missingBaseURL
      }
      return nil
    }
    guard
      let normalized = normalizeBaseURL(
        trimmed,
        allowPrivateHttp: provider.allowsPrivateHttpBaseURL
      )
    else {
      throw ProviderConfigStoreError.invalidBaseURL
    }
    return normalized
  }

  private static func isPrivateOrLocalHost(_ hostname: String) -> Bool {
    let host = hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || host == "127.0.0.1" || host == "::1" {
      return true
    }
    if host.hasSuffix(".local") {
      return true
    }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    if parts.count == 4 {
      if parts[0] == 10 { return true }
      if parts[0] == 192, parts[1] == 168 { return true }
      if parts[0] == 172, (16...31).contains(parts[1]) { return true }
      if parts[0] == 169, parts[1] == 254 { return true }
    }
    // Unique-local IPv6 fc00::/7
    if host.hasPrefix("fc") || host.hasPrefix("fd") {
      return true
    }
    return false
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

  /// Cross-process mutex shared with QuotaCLI's TypeScript ProviderConfigStore.
  private func withWriteLock<T>(_ action: () throws -> T) throws -> T {
    let lockURL = URL(fileURLWithPath: "\(fileURL.path).lock", isDirectory: true)
    let ownerURL = lockURL.appendingPathComponent("owner", isDirectory: false)
    let directory = fileURL.deletingLastPathComponent()
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

    let deadline = Date().addingTimeInterval(10)
    while true {
      do {
        try fileManager.createDirectory(
          at: lockURL,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]
        )
        do {
          try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(
            to: ownerURL,
            options: .withoutOverwriting
          )
        } catch {
          _ = Self.discardWriteLock(lockURL: lockURL, state: "failed")
          throw ProviderConfigStoreError.locked
        }
        break
      } catch {
        if error as? ProviderConfigStoreError == .locked {
          throw error
        }
        guard (error as? CocoaError)?.code == .fileWriteFileExists else {
          throw ProviderConfigStoreError.locked
        }
        if Self.removeStaleWriteLock(lockURL: lockURL, ownerURL: ownerURL) {
          continue
        }
        guard Date() < deadline else { throw ProviderConfigStoreError.locked }
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
    defer { _ = Self.discardWriteLock(lockURL: lockURL, state: "released") }
    return try action()
  }

  private static func removeStaleWriteLock(lockURL: URL, ownerURL: URL) -> Bool {
    let fileManager = FileManager.default
    let reclaimURL = URL(fileURLWithPath: "\(lockURL.path).reclaim", isDirectory: true)
    do {
      try fileManager.createDirectory(
        at: reclaimURL,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      return false
    }
    defer { try? fileManager.removeItem(at: reclaimURL) }

    guard isWriteLockStale(lockURL: lockURL, ownerURL: ownerURL) else { return false }
    return discardWriteLock(lockURL: lockURL, state: "stale")
  }

  private static func discardWriteLock(lockURL: URL, state: String) -> Bool {
    let fileManager = FileManager.default
    let discardedURL = URL(
      fileURLWithPath:
        "\(lockURL.path).\(state)-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
      isDirectory: true
    )
    do {
      try fileManager.moveItem(at: lockURL, to: discardedURL)
    } catch {
      return (error as? CocoaError)?.code == .fileNoSuchFile
    }
    try? fileManager.removeItem(at: discardedURL)
    return true
  }

  private static func isWriteLockStale(lockURL: URL, ownerURL: URL) -> Bool {
    let fileManager = FileManager.default
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: lockURL.path),
      let modifiedAt = attributes[.modificationDate] as? Date
    else {
      return !fileManager.fileExists(atPath: lockURL.path)
    }
    let age = Date().timeIntervalSince(modifiedAt)

    if let data = try? Data(contentsOf: ownerURL),
      let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ),
      let ownerPID = Int32(text), ownerPID > 0
    {
      if age >= 5 { return true }
      errno = 0
      if kill(ownerPID, 0) == 0 || errno == EPERM {
        return false
      }
      return errno == ESRCH
    }
    return age >= 1
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
  case missingBaseURL
  case invalidBaseURL
  case notConfigurable
  case unreadable
  case invalid
  case insecurePermissions
  case locked
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
