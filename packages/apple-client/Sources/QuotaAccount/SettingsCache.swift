import Foundation
import QuotaAlerts

/// The last Account settings document this device held, and the validator it is current at.
///
/// Lives beside the last-good Account summary cache, per Account, and is cleared on sign-out.
/// The file is not `WireCodec` JSON: `AccountSettingsDocument` keys are the wire's own
/// snake_case, and that coder would fail them.
public struct CachedAccountSettings: Equatable, Sendable {
  public var accountID: String
  public var etag: String?
  public var document: AccountSettingsDocument

  public init(accountID: String, etag: String?, document: AccountSettingsDocument) {
    self.accountID = accountID
    self.etag = etag
    self.document = document
  }
}

public protocol AccountSettingsStore: Sendable {
  func load() throws -> CachedAccountSettings?
  func save(_ value: CachedAccountSettings) throws
  func clear() throws
}

public final class MemoryAccountSettingsStore: AccountSettingsStore, @unchecked Sendable {
  private let lock = NSLock()
  private var value: CachedAccountSettings?

  public init(value: CachedAccountSettings? = nil) {
    self.value = value
  }

  public func load() throws -> CachedAccountSettings? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  public func save(_ value: CachedAccountSettings) throws {
    lock.lock()
    self.value = value
    lock.unlock()
  }

  public func clear() throws {
    lock.lock()
    value = nil
    lock.unlock()
  }
}

public struct ProtectedFileAccountSettingsStore: AccountSettingsStore, Sendable {
  public let fileURL: URL

  public init(directory: URL) {
    self.fileURL = directory.appendingPathComponent("account-settings.json", isDirectory: false)
  }

  public static func applicationSupport() throws -> ProtectedFileAccountSettingsStore {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = root.appendingPathComponent("Quota", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = directory
    try? mutable.setResourceValues(values)
    return ProtectedFileAccountSettingsStore(directory: directory)
  }

  public func load() throws -> CachedAccountSettings? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let data = try Data(contentsOf: fileURL)
    return try AccountSettingsCacheFile.decode(data)
  }

  public func save(_ value: CachedAccountSettings) throws {
    let data = try AccountSettingsCacheFile.encode(value)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    #if os(iOS)
      try data.write(
        to: fileURL,
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
      )
    #else
      try data.write(to: fileURL, options: [.atomic])
    #endif
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = fileURL
    try? mutable.setResourceValues(values)
  }

  public func clear() throws {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
  }
}

/// On-disk envelope: account id, ETag, and the GET document as a nested JSON object.
private enum AccountSettingsCacheFile {
  static func encode(_ value: CachedAccountSettings) throws -> Data {
    let document = try JSONSerialization.jsonObject(with: try responseJSON(value.document))
    var object: [String: Any] = [
      "account_id": value.accountID,
      "document": document,
    ]
    if let etag = value.etag {
      object["etag"] = etag
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  static func decode(_ data: Data) throws -> CachedAccountSettings {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let accountID = object["account_id"] as? String,
      let documentObject = object["document"]
    else {
      throw AccountStoreError.unreadable
    }
    let body = try JSONSerialization.data(withJSONObject: documentObject)
    let document = try AccountSettingsDocument.decode(body)
    let etag = object["etag"] as? String
    return CachedAccountSettings(accountID: accountID, etag: etag, document: document)
  }

  /// The GET shape, including `revision` and `updated_at`. `AccountSettingsDocument.encode`
  /// writes the update request instead, so the cache spells this itself.
  static func responseJSON(_ document: AccountSettingsDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(ResponseDocument(document))
  }
}

/// GET-shaped encoding of a cached document. Nested `alerts` / `budget` / `history` already
/// spell snake_case keys, and this wrapper does the same for the envelope. A K6 file with no
/// `history` still loads: `AccountSettingsDocument.decode` treats that as `sync: false`.
private struct ResponseDocument: Encodable {
  var protocolVersion = 2
  var revision: Int
  var updatedAt: String?
  var alerts: AccountSettingsDocument.Alerts
  var budget: AccountSettingsDocument.Budget
  var history: AccountSettingsDocument.History

  init(_ document: AccountSettingsDocument) {
    revision = document.revision
    if let updatedAt = document.updatedAt {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      self.updatedAt = formatter.string(from: updatedAt)
    } else {
      updatedAt = nil
    }
    alerts = document.alerts
    budget = document.budget
    history = document.history
  }

  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
    case revision
    case updatedAt = "updated_at"
    case alerts
    case budget
    case history
  }
}
