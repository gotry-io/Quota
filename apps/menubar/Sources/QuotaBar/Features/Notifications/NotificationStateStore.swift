import Foundation
import QuotaAlerts

protocol NotificationStateStore: Sendable {
  func load() throws -> AlertDedupState
  func save(_ state: AlertDedupState) throws
  func clear() throws
}

/// In-memory store for tests and for a MenuBarViewModel that is not talking to a live helper.
final class InMemoryNotificationStateStore: NotificationStateStore, @unchecked Sendable {
  private let lock = NSLock()
  private var state: AlertDedupState = .empty

  init(state: AlertDedupState = .empty) {
    self.state = state
  }

  func load() throws -> AlertDedupState {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  func save(_ state: AlertDedupState) throws {
    lock.lock()
    self.state = state
    lock.unlock()
  }

  func clear() throws {
    lock.lock()
    state = .empty
    lock.unlock()
  }
}

/// Owner-only JSON at `Application Support/QuotaBar/notification-state.json`.
///
/// The file is mode 0600 and, where the platform supports it, complete file protection. It is
/// not UserDefaults: the keys name subscriptions and remaining percents.
struct FileNotificationStateStore: NotificationStateStore, Sendable {
  let fileURL: URL

  init(directory: URL) {
    fileURL = directory.appendingPathComponent("notification-state.json", isDirectory: false)
  }

  static func applicationSupport() -> FileNotificationStateStore {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return FileNotificationStateStore(
      directory: root.appendingPathComponent("QuotaBar", isDirectory: true)
    )
  }

  func load() throws -> AlertDedupState {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
    let data = try Data(contentsOf: fileURL)
    return try AlertStateJSON.decode(data)
  }

  func save(_ state: AlertDedupState) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try AlertStateJSON.encode(state)
    #if os(iOS)
      try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    #else
      try data.write(to: fileURL, options: [.atomic])
    #endif
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    #if os(iOS)
      values.fileProtection = .complete
    #endif
    var mutable = fileURL
    try? mutable.setResourceValues(values)
  }

  func clear() throws {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
  }
}
