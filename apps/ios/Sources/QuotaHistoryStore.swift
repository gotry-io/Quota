import Foundation
import QuotaPresentation
import QuotaWire

/// Watermarks for one Account, in the Account cache directory. Cleared on sign-out and on
/// `409 history_sync_off`.
struct QuotaHistoryWatermarkFile: Codable, Equatable, Sendable {
  struct Series: Codable, Equatable, Sendable {
    var provider: String
    var fingerprint: String
    var windowID: String
    var newestBucketStart: Date?
    var lastUploaded: [QuotaHistorySync.Bucket]
  }

  struct Account: Codable, Equatable, Sendable {
    var observedSync: Bool
    var series: [Series]

    static let empty = Account(observedSync: false, series: [])
  }

  var accounts: [String: Account]

  static let empty = QuotaHistoryWatermarkFile(accounts: [:])
}

protocol QuotaHistoryWatermarkStoring: Sendable {
  func load() throws -> QuotaHistoryWatermarkFile
  func save(_ value: QuotaHistoryWatermarkFile) throws
  func clear() throws
}

/// The last Account history read for one subscription, beside `account-usage.json`.
/// A later read offers the ETag; `304` keeps this body.
struct QuotaHistoryReadCacheFile: Codable, Equatable, Sendable {
  struct Entry: Codable, Equatable, Sendable {
    var accountID: String
    var provider: String
    var fingerprint: String
    var since: Date
    var etag: String?
    var body: QuotaHistoryReadResponse

    func matches(accountID: String, provider: String, fingerprint: String, since: Date) -> Bool {
      self.accountID == accountID && self.provider == provider && self.fingerprint == fingerprint
        && abs(self.since.timeIntervalSince(since)) < 1
    }
  }

  var entries: [Entry]

  static let empty = QuotaHistoryReadCacheFile(entries: [])

  func entry(
    accountID: String,
    provider: String,
    fingerprint: String,
    since: Date
  ) -> Entry? {
    entries.first {
      $0.matches(accountID: accountID, provider: provider, fingerprint: fingerprint, since: since)
    }
  }
}

protocol QuotaHistoryReadStoring: Sendable {
  func load() throws -> QuotaHistoryReadCacheFile
  func save(_ value: QuotaHistoryReadCacheFile) throws
  func clear() throws
}

final class MemoryQuotaHistoryWatermarkStore: QuotaHistoryWatermarkStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var value = QuotaHistoryWatermarkFile.empty

  func load() throws -> QuotaHistoryWatermarkFile {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func save(_ value: QuotaHistoryWatermarkFile) throws {
    lock.lock()
    self.value = value
    lock.unlock()
  }

  func clear() throws {
    lock.lock()
    value = .empty
    lock.unlock()
  }
}

final class MemoryQuotaHistoryReadStore: QuotaHistoryReadStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var value = QuotaHistoryReadCacheFile.empty

  func load() throws -> QuotaHistoryReadCacheFile {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func save(_ value: QuotaHistoryReadCacheFile) throws {
    lock.lock()
    self.value = value
    lock.unlock()
  }

  func clear() throws {
    lock.lock()
    value = .empty
    lock.unlock()
  }
}

struct FileQuotaHistoryWatermarkStore: QuotaHistoryWatermarkStoring {
  let fileURL: URL

  init(directory: URL) {
    fileURL = directory.appendingPathComponent("quota-history-watermarks.json", isDirectory: false)
  }

  static func applicationSupport() -> FileQuotaHistoryWatermarkStore? {
    guard let directory = QuotaAccountCacheDirectory.url() else { return nil }
    return FileQuotaHistoryWatermarkStore(directory: directory)
  }

  func load() throws -> QuotaHistoryWatermarkFile {
    try QuotaHistoryJSONFile.load(QuotaHistoryWatermarkFile.self, from: fileURL) ?? .empty
  }

  func save(_ value: QuotaHistoryWatermarkFile) throws {
    try QuotaHistoryJSONFile.save(value, to: fileURL)
  }

  func clear() throws {
    try QuotaHistoryJSONFile.remove(fileURL)
  }
}

struct FileQuotaHistoryReadStore: QuotaHistoryReadStoring {
  let fileURL: URL

  init(directory: URL) {
    fileURL = directory.appendingPathComponent("quota-history-read.json", isDirectory: false)
  }

  static func applicationSupport() -> FileQuotaHistoryReadStore? {
    guard let directory = QuotaAccountCacheDirectory.url() else { return nil }
    return FileQuotaHistoryReadStore(directory: directory)
  }

  func load() throws -> QuotaHistoryReadCacheFile {
    try QuotaHistoryJSONFile.load(QuotaHistoryReadCacheFile.self, from: fileURL) ?? .empty
  }

  func save(_ value: QuotaHistoryReadCacheFile) throws {
    try QuotaHistoryJSONFile.save(value, to: fileURL)
  }

  func clear() throws {
    try QuotaHistoryJSONFile.remove(fileURL)
  }
}

enum QuotaAccountCacheDirectory {
  /// Application Support/Quota, the directory the Account summary and settings caches use.
  static func url() -> URL? {
    guard
      let root = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    else { return nil }
    let directory = root.appendingPathComponent("Quota", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = directory
    try? mutable.setResourceValues(values)
    return directory
  }
}

enum QuotaHistoryJSONFile {
  static func load<T: Decodable>(_ type: T.Type, from fileURL: URL) throws -> T? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let data = try Data(contentsOf: fileURL)
    guard let value = try? WireCodec.decode(type, from: data) else {
      try? remove(fileURL)
      return nil
    }
    return value
  }

  static func save<T: Encodable>(_ value: T, to fileURL: URL) throws {
    let data = try WireCodec.encode(value)
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

  static func remove(_ fileURL: URL) throws {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
  }
}
