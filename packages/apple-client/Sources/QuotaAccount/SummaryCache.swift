import Foundation
import QuotaWire

public protocol AccountSummaryStore: Sendable {
  func load() throws -> CachedAccountSummary?
  func save(_ value: CachedAccountSummary) throws
  func clear() throws
}

public final class MemoryAccountSummaryStore: AccountSummaryStore, @unchecked Sendable {
  private let lock = NSLock()
  private var value: CachedAccountSummary?

  public init(value: CachedAccountSummary? = nil) {
    self.value = value
  }

  public func load() throws -> CachedAccountSummary? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  public func save(_ value: CachedAccountSummary) throws {
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

public struct ProtectedFileAccountSummaryStore: AccountSummaryStore, Sendable {
  public let fileURL: URL

  public init(directory: URL) {
    self.fileURL = directory.appendingPathComponent("account-summary.json", isDirectory: false)
  }

  public static func applicationSupport() throws -> ProtectedFileAccountSummaryStore {
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
    return ProtectedFileAccountSummaryStore(directory: directory)
  }

  public func load() throws -> CachedAccountSummary? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let data = try Data(contentsOf: fileURL)
    return try WireCodec.decode(CachedAccountSummary.self, from: data)
  }

  public func save(_ value: CachedAccountSummary) throws {
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
