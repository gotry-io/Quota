import Foundation
import QuotaAlerts

protocol IOSAlertStateStore: Sendable {
  func load() throws -> AlertDedupState
  func save(_ state: AlertDedupState) throws
  func clear() throws
}

final class InMemoryIOSAlertStateStore: IOSAlertStateStore, @unchecked Sendable {
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

/// App-private JSON at `Application Support/alert-state.json`, complete file protection.
struct FileIOSAlertStateStore: IOSAlertStateStore, Sendable {
  let fileURL: URL

  init(directory: URL) {
    fileURL = directory.appendingPathComponent("alert-state.json", isDirectory: false)
  }

  static func applicationSupport() -> FileIOSAlertStateStore {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return FileIOSAlertStateStore(directory: root)
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
    try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = fileURL
    try? mutable.setResourceValues(values)
  }

  func clear() throws {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
  }
}
