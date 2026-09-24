import Foundation
import QuotaAlerts
import Testing

@testable import QuotaAlertDelivery

struct NotificationStateStoreTests {
  @Test func theStateFileIsOwnerOnlyReadsBackEveryKeyAndClearRemovesIt() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("QuotaAlertDeliveryTests.state.\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = FileAlertStateStore(
      fileURL: directory.appendingPathComponent("state.json", isDirectory: false)
    )
    let resetsAt = Date(timeIntervalSince1970: 1_773_576_000)
    let state = AlertDedupState(
      fired: [
        AlertDedupKey(
          kind: .threshold,
          selector: "codex_acct",
          windowID: "weekly",
          resetsAt: resetsAt,
          threshold: 20
        ),
        AlertDedupKey(
          kind: .pace,
          selector: "codex_acct",
          windowID: "weekly",
          resetsAt: resetsAt,
          threshold: nil
        ),
      ],
      readings: [
        AlertStoredReading(
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
}
