import Foundation
import Testing

@testable import QuotaBar

struct NotificationStateStoreTests {
  @Test func writtenFileIsOwnerReadWriteOnlyAndClearRemovesIt() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("QuotaBarTests.notification-state.\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = FileNotificationStateStore(directory: directory)
    let resetsAt = Date(timeIntervalSince1970: 1_773_576_000)
    let state = NotificationDedupState(
      fired: [
        NotificationDedupKey(
          selector: "codex_acct",
          windowID: "weekly",
          resetsAt: resetsAt,
          threshold: 20
        )
      ],
      readings: [
        NotificationStoredReading(
          selector: "codex_acct",
          windowID: "weekly",
          remainingPercent: 18,
          resetsAt: resetsAt
        )
      ]
    )
    try store.save(state)

    let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    let permissions = attributes[.posixPermissions] as! NSNumber
    #expect(permissions.uint16Value & 0o777 == 0o600)

    let loaded = try store.load()
    #expect(loaded.sorted() == state.sorted())

    try store.clear()
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    #expect(try store.load() == .empty)
  }

  @Test func memoryStoreRoundTripsAndClearEmpties() throws {
    let store = InMemoryNotificationStateStore()
    let state = NotificationDedupState(
      fired: [
        NotificationDedupKey(
          selector: "codex_acct", windowID: "weekly", resetsAt: nil, threshold: 10)
      ],
      readings: []
    )
    try store.save(state)
    #expect(try store.load() == state)
    try store.clear()
    #expect(try store.load() == .empty)
  }
}
