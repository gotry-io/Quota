import Foundation
import QuotaAlerts

public protocol AlertStateStore: Sendable {
  func load() throws -> AlertDedupState
  func save(_ state: AlertDedupState) throws
  func clear() throws
}

/// In-memory store for tests and for a view model that is not talking to a live helper.
public final class InMemoryAlertStateStore: AlertStateStore, @unchecked Sendable {
  private let lock = NSLock()
  private var state: AlertDedupState = .empty

  public init(state: AlertDedupState = .empty) {
    self.state = state
  }

  public func load() throws -> AlertDedupState {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  public func save(_ state: AlertDedupState) throws {
    lock.lock()
    self.state = state
    lock.unlock()
  }

  public func clear() throws {
    lock.lock()
    state = .empty
    lock.unlock()
  }
}

/// Owner-only JSON at a file URL the app supplies.
///
/// The file is mode 0600 and, where the platform supports it, complete file protection. It is
/// not UserDefaults: the keys name subscriptions and remaining percents. Each app chooses the
/// URL so shipped file names stay exactly what those releases wrote.
public struct FileAlertStateStore: AlertStateStore, Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> AlertDedupState {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
    let data = try Data(contentsOf: fileURL)
    return try AlertStateJSON.decode(data)
  }

  public func save(_ state: AlertDedupState) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try AlertStateJSON.encode(state)
    #if os(iOS)
      try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    #else
      try data.write(to: fileURL, options: [.atomic])
    #endif
    var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
    #if os(iOS)
      attributes[.protectionKey] = FileProtectionType.complete
    #endif
    try FileManager.default.setAttributes(attributes, ofItemAtPath: fileURL.path)
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
