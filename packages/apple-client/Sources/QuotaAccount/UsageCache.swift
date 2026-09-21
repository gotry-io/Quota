import Foundation
import QuotaWire

/// One activity body this device held, and the validator it is current at.
public struct CachedUsageActivity: Codable, Equatable, Sendable {
  public var from: String
  public var to: String
  public var etag: String
  public var fetchedAt: Date
  public var response: AccountUsageActivityResponse

  public init(
    from: String,
    to: String,
    etag: String,
    fetchedAt: Date,
    response: AccountUsageActivityResponse
  ) {
    self.from = from
    self.to = to
    self.etag = etag
    self.fetchedAt = fetchedAt
    self.response = response
  }
}

/// One period body this device held, keyed beside the Account summary cache.
public struct CachedUsagePeriod: Codable, Equatable, Sendable {
  public var etag: String
  public var fetchedAt: Date
  public var response: AccountUsagePeriodResponse

  public init(etag: String, fetchedAt: Date, response: AccountUsagePeriodResponse) {
    self.etag = etag
    self.fetchedAt = fetchedAt
    self.response = response
  }
}

/// Period bodies and the activity body for one Account, with their ETags.
public struct CachedAccountUsage: Codable, Equatable, Sendable {
  /// Rolling range keys change daily; keep only this many newest period bodies.
  public static let periodRetention = 8

  public var accountID: String
  public var activity: CachedUsageActivity?
  public var periods: [String: CachedUsagePeriod]

  public init(
    accountID: String,
    activity: CachedUsageActivity? = nil,
    periods: [String: CachedUsagePeriod] = [:]
  ) {
    self.accountID = accountID
    self.activity = activity
    self.periods = periods
  }

  public mutating func capPeriods(limit: Int = periodRetention) {
    guard periods.count > limit else { return }
    let keep = periods.sorted { lhs, rhs in
      if lhs.value.fetchedAt != rhs.value.fetchedAt {
        return lhs.value.fetchedAt > rhs.value.fetchedAt
      }
      return lhs.key > rhs.key
    }.prefix(limit)
    periods = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
  }
}

public protocol AccountUsageStore: Sendable {
  func load() throws -> CachedAccountUsage?
  func save(_ value: CachedAccountUsage) throws
  func clear() throws
}

public final class MemoryAccountUsageStore: AccountUsageStore, @unchecked Sendable {
  private let lock = NSLock()
  private var value: CachedAccountUsage?

  public init(value: CachedAccountUsage? = nil) {
    self.value = value
  }

  public func load() throws -> CachedAccountUsage? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  public func save(_ value: CachedAccountUsage) throws {
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

public struct ProtectedFileAccountUsageStore: AccountUsageStore, Sendable {
  public let fileURL: URL

  public init(directory: URL) {
    self.fileURL = directory.appendingPathComponent("account-usage.json", isDirectory: false)
  }

  public static func applicationSupport() throws -> ProtectedFileAccountUsageStore {
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
    return ProtectedFileAccountUsageStore(directory: directory)
  }

  public func load() throws -> CachedAccountUsage? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let data = try Data(contentsOf: fileURL)
    return try WireCodec.decode(CachedAccountUsage.self, from: data)
  }

  public func save(_ value: CachedAccountUsage) throws {
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

  public func clear() throws {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
  }
}

/// What restore reads in one actor hop: the session (one Keychain read) and the caches bound to it.
public struct RestoredAccountState: Sendable {
  public var session: AccountSession?
  public var summary: CachedAccountSummary?
  public var usage: CachedAccountUsage?

  public init(
    session: AccountSession?,
    summary: CachedAccountSummary?,
    usage: CachedAccountUsage?
  ) {
    self.session = session
    self.summary = summary
    self.usage = usage
  }
}

public enum AccountSessionPresence: Equatable, Sendable {
  case signedIn(AccountSession)
  case signedOut
  /// The Keychain could not be read (locked WhenUnlocked item, or a transient failure).
  case unknown
}
