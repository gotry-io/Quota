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
    /// The oldest bucket this iPhone uploaded in the current on-period that Relay must still
    /// hold. Once it stops being live the watermark is the evidence, and the next accepted
    /// chunk re-seeds it (`reseed_oldest` in the history sync fixture). A file
    /// written before this field has none, and starts from its next upload.
    var oldestBucketStart: Date? = nil
    /// A shorter `duration_seconds` Relay answered for the window (another device declared
    /// it), declared instead of the collector's until an answer names a longer one, so the two
    /// devices stop rewriting each other's expiry (ADR 0062, amendment 2026-09-24). A file
    /// written before this field has none.
    var adoptedDurationSeconds: Int? = nil
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

/// The last Account history read for each subscription, beside `account-usage.json`.
/// One entry per subscription: a later read replaces it. A cached body is reused when `since`
/// has moved to the next UTC day; the chart clamps. `304` sends the ETag only when `since`
/// still matches.
struct QuotaHistoryReadCacheFile: Codable, Equatable, Sendable {
  struct Entry: Codable, Equatable, Sendable {
    var accountID: String
    var provider: String
    var fingerprint: String
    var since: Date
    var etag: String?
    var body: QuotaHistoryReadResponse

    func sameSubscription(accountID: String, provider: String, fingerprint: String) -> Bool {
      self.accountID == accountID && self.provider == provider && self.fingerprint == fingerprint
    }

    func sinceMatches(_ since: Date) -> Bool {
      abs(self.since.timeIntervalSince(since)) < 1
    }
  }

  var entries: [Entry]

  static let empty = QuotaHistoryReadCacheFile(entries: [])

  /// The newest cached body for this subscription, whatever `since` it was stored under.
  func entry(accountID: String, provider: String, fingerprint: String) -> Entry? {
    var found: Entry?
    for entry in entries
    where entry.sameSubscription(
      accountID: accountID,
      provider: provider,
      fingerprint: fingerprint
    ) {
      if let current = found, entry.since < current.since { continue }
      found = entry
    }
    return found
  }

  mutating func replace(_ entry: Entry) {
    entries.removeAll {
      $0.sameSubscription(
        accountID: entry.accountID,
        provider: entry.provider,
        fingerprint: entry.fingerprint
      )
    }
    entries.append(entry)
  }

  /// One body per subscription. A file written before that rule keeps the newest `since`.
  func keepingNewestPerSubscription() -> QuotaHistoryReadCacheFile {
    var best: [String: Entry] = [:]
    var order: [String] = []
    for entry in entries {
      let key = "\(entry.accountID)\u{0}\(entry.provider)\u{0}\(entry.fingerprint)"
      if let current = best[key] {
        if entry.since >= current.since { best[key] = entry }
      } else {
        order.append(key)
        best[key] = entry
      }
    }
    return QuotaHistoryReadCacheFile(entries: order.compactMap { best[$0] })
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
  private let memory = QuotaHistoryReadMemory()

  init(directory: URL) {
    fileURL = directory.appendingPathComponent("quota-history-read.json", isDirectory: false)
  }

  static func applicationSupport() -> FileQuotaHistoryReadStore? {
    guard let directory = QuotaAccountCacheDirectory.url() else { return nil }
    return FileQuotaHistoryReadStore(directory: directory)
  }

  /// Decodes the file on the first call. Later calls return that value until `save` or `clear`.
  func load() throws -> QuotaHistoryReadCacheFile {
    if let cached = memory.cached() { return cached }
    let decoded =
      try QuotaHistoryJSONFile.load(QuotaHistoryReadCacheFile.self, from: fileURL) ?? .empty
    let compact = decoded.keepingNewestPerSubscription()
    if compact != decoded {
      try QuotaHistoryJSONFile.save(compact, to: fileURL)
    }
    memory.store(compact)
    return compact
  }

  func save(_ value: QuotaHistoryReadCacheFile) throws {
    let compact = value.keepingNewestPerSubscription()
    memory.store(compact)
    try QuotaHistoryJSONFile.save(compact, to: fileURL)
  }

  func clear() throws {
    memory.store(.empty)
    try QuotaHistoryJSONFile.remove(fileURL)
  }
}

/// The decoded read cache. The file is this process's, so a second `load` does not decode it again.
private final class QuotaHistoryReadMemory: @unchecked Sendable {
  private let lock = NSLock()
  private var value: QuotaHistoryReadCacheFile?
  private var ready = false

  func cached() -> QuotaHistoryReadCacheFile? {
    lock.lock()
    defer { lock.unlock() }
    return ready ? value : nil
  }

  func store(_ file: QuotaHistoryReadCacheFile) {
    lock.lock()
    value = file
    ready = true
    lock.unlock()
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
