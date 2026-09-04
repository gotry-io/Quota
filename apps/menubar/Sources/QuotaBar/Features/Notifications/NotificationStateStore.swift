import Foundation

protocol NotificationStateStore: Sendable {
  func load() throws -> NotificationDedupState
  func save(_ state: NotificationDedupState) throws
  func clear() throws
}

/// In-memory store for tests and for a MenuBarViewModel that is not talking to a live helper.
final class InMemoryNotificationStateStore: NotificationStateStore, @unchecked Sendable {
  private let lock = NSLock()
  private var state: NotificationDedupState = .empty

  init(state: NotificationDedupState = .empty) {
    self.state = state
  }

  func load() throws -> NotificationDedupState {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  func save(_ state: NotificationDedupState) throws {
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

  func load() throws -> NotificationDedupState {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
    let data = try Data(contentsOf: fileURL)
    return try NotificationStateJSON.decode(data)
  }

  func save(_ state: NotificationDedupState) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try NotificationStateJSON.encode(state)
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

enum NotificationStateJSON {
  static func encode(_ state: NotificationDedupState) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(NotificationDedupStateDTO(state))
  }

  static func decode(_ data: Data) throws -> NotificationDedupState {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(NotificationDedupStateDTO.self, from: data).model
  }
}

private struct NotificationDedupStateDTO: Codable {
  var fired: [NotificationDedupKeyDTO]
  var readings: [NotificationStoredReadingDTO]

  init(_ state: NotificationDedupState) {
    let sorted = state.sorted()
    fired = sorted.fired.map(NotificationDedupKeyDTO.init)
    readings = sorted.readings.map(NotificationStoredReadingDTO.init)
  }

  var model: NotificationDedupState {
    NotificationDedupState(
      fired: fired.map(\.model),
      readings: readings.map(\.model)
    ).sorted()
  }
}

private struct NotificationDedupKeyDTO: Codable {
  var selector: String
  var windowID: String
  var resetsAt: Date?
  var threshold: Int?

  init(_ key: NotificationDedupKey) {
    selector = key.selector
    windowID = key.windowID
    resetsAt = key.resetsAt
    threshold = key.threshold
  }

  var model: NotificationDedupKey {
    NotificationDedupKey(
      selector: selector,
      windowID: windowID,
      resetsAt: resetsAt,
      threshold: threshold
    )
  }

  enum CodingKeys: String, CodingKey {
    case selector
    case windowID = "window_id"
    case resetsAt = "resets_at"
    case threshold
  }
}

private struct NotificationStoredReadingDTO: Codable {
  var selector: String
  var windowID: String
  var remainingPercent: Double
  var resetsAt: Date?

  init(_ reading: NotificationStoredReading) {
    selector = reading.selector
    windowID = reading.windowID
    remainingPercent = reading.remainingPercent
    resetsAt = reading.resetsAt
  }

  var model: NotificationStoredReading {
    NotificationStoredReading(
      selector: selector,
      windowID: windowID,
      remainingPercent: remainingPercent,
      resetsAt: resetsAt
    )
  }

  enum CodingKeys: String, CodingKey {
    case selector
    case windowID = "window_id"
    case remainingPercent = "remaining_percent"
    case resetsAt = "resets_at"
  }
}
