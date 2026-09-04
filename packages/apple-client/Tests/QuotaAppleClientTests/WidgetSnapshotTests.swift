import Foundation
import QuotaWidgetData
import Testing

struct WidgetSnapshotTests {
  @Test
  func protectedFileRoundtripAndClear() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = ProtectedFileWidgetSnapshotStore(directory: directory)
    #expect(store.fileURL.lastPathComponent == "widget-snapshot-v1.json")
    #expect(try store.load() == nil)

    let snapshot = makeSnapshot()
    try store.save(snapshot)
    let loaded = try store.load()
    #expect(loaded == snapshot)

    let encoded = try String(contentsOf: store.fileURL, encoding: .utf8)
    let forbidden = [
      "account_id", "account_label", "fingerprint", "device_id", "device_name", "source",
      "sequence", "session", "token", "credential", "summary",
    ]
    for key in forbidden {
      #expect(!encoded.contains("\"\(key)\""), "encoded snapshot must not contain key \(key)")
    }
    #expect(encoded.contains("\"version\":2"))
    #expect(encoded.contains("selection_id"))
    #expect(encoded.contains("0123456789ab"))
    #expect(encoded.contains("provider_id"))
    #expect(encoded.contains("remaining_percent"))
    #expect(encoded.contains("input_tokens"))
    #expect(encoded.contains("amount_microusd"))
    #expect(encoded.contains("\"unit\":\"usd\""))

    try store.clear()
    #expect(try store.load() == nil)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
  }

  @Test
  func rejectsInvalidVersion() throws {
    let json = """
      {
        "version": 3,
        "fetched_at": "2026-08-14T16:00:00Z",
        "items": [],
        "today": {
          "input_tokens": 0,
          "output_tokens": 0,
          "cost": { "status": "unavailable" }
        }
      }
      """
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(json)
    }
  }

  @Test
  func rejectsItemCountOverLimit() throws {
    let items = (0..<17).map { index in
      """
      {
        "selection_id": "0123456789ab",
        "provider_id": "codex",
        "provider_display_name": "Codex",
        "window_title": "Window \(index)",
        "remaining_percent": 50,
        "state": "available"
      }
      """
    }.joined(separator: ",")
    let json = """
      {
        "version": 2,
        "fetched_at": "2026-08-14T16:00:00Z",
        "items": [\(items)],
        "today": {
          "input_tokens": 0,
          "output_tokens": 0,
          "cost": { "status": "unavailable" }
        }
      }
      """
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(json)
    }
  }

  @Test
  func rejectsInvalidText() throws {
    let emptyProvider = makeJSON(
      providerID: "",
      displayName: "Codex",
      windowTitle: "5h"
    )
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(emptyProvider)
    }

    let paddedName = makeJSON(
      providerID: "codex",
      displayName: " Codex ",
      windowTitle: "5h"
    )
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(paddedName)
    }

    let overlongTitle = makeJSON(
      providerID: "codex",
      displayName: "Codex",
      windowTitle: String(repeating: "w", count: 129)
    )
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(overlongTitle)
    }

    let uppercaseSelection = makeJSON(
      providerID: "codex",
      displayName: "Codex",
      windowTitle: "5h",
      selectionID: "ABCDEF123456"
    )
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(uppercaseSelection)
    }

    let shortSelection = makeJSON(
      providerID: "codex",
      displayName: "Codex",
      windowTitle: "5h",
      selectionID: "0123456789a"
    )
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(shortSelection)
    }

    let nonHexSelection = makeJSON(
      providerID: "codex",
      displayName: "Codex",
      windowTitle: "5h",
      selectionID: "0123456789ag"
    )
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(nonHexSelection)
    }
  }

  @Test
  func rejectsMissingSelectionID() throws {
    let json = """
      {
        "version": 2,
        "fetched_at": "2026-08-14T16:00:00Z",
        "items": [{
          "provider_id": "codex",
          "provider_display_name": "Codex",
          "window_title": "5h",
          "remaining_percent": 50,
          "state": "available"
        }],
        "today": {
          "input_tokens": 0,
          "output_tokens": 0,
          "cost": { "status": "unavailable" }
        }
      }
      """
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(json)
    }
  }

  @Test
  func rejectsInvalidValues() throws {
    let badPercent = makeJSON(
      providerID: "codex",
      displayName: "Codex",
      windowTitle: "5h",
      remainingPercent: 101
    )
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(badPercent)
    }

    let nanPercent = """
      {
        "version": 2,
        "fetched_at": "2026-08-14T16:00:00Z",
        "items": [{
          "selection_id": "0123456789ab",
          "provider_id": "codex",
          "provider_display_name": "Codex",
          "window_title": "5h",
          "remaining_percent": "nan",
          "state": "available"
        }],
        "today": {
          "input_tokens": 0,
          "output_tokens": 0,
          "cost": { "status": "unavailable" }
        }
      }
      """
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(nanPercent)
    }

    let negativeTokens = """
      {
        "version": 2,
        "fetched_at": "2026-08-14T16:00:00Z",
        "items": [],
        "today": {
          "input_tokens": -1,
          "output_tokens": 0,
          "cost": { "status": "unavailable" }
        }
      }
      """
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(negativeTokens)
    }

    let badMicrousd = """
      {
        "version": 2,
        "fetched_at": "2026-08-14T16:00:00Z",
        "items": [],
        "today": {
          "input_tokens": 0,
          "output_tokens": 0,
          "cost": { "status": "complete", "amount_microusd": "01" }
        }
      }
      """
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(badMicrousd)
    }

    let unknownUnit = """
      {
        "version": 2,
        "fetched_at": "2026-08-14T16:00:00Z",
        "items": [{
          "selection_id": "0123456789ab",
          "provider_id": "codex",
          "provider_display_name": "Codex",
          "window_title": "5h",
          "remaining_percent": 50,
          "unit": "cny",
          "state": "available"
        }],
        "today": {
          "input_tokens": 0,
          "output_tokens": 0,
          "cost": { "status": "unavailable" }
        }
      }
      """
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(unknownUnit)
    }
  }

  @Test
  func rejectsNonFiniteDates() throws {
    let nonFinite = Date(timeIntervalSinceReferenceDate: .nan)
    let badFetched = WidgetSnapshot(
      fetchedAt: nonFinite,
      items: [],
      today: WidgetTodayUsage(
        inputTokens: 0,
        outputTokens: 0,
        cost: WidgetCost(status: .unavailable)
      )
    )
    #expect(!badFetched.isValid)
    #expect(throws: EncodingError.self) {
      _ = try encodeSnapshot(badFetched)
    }

    let badResets = WidgetQuotaItem(
      selectionID: "0123456789ab",
      providerID: "codex",
      providerDisplayName: "Codex",
      windowTitle: "5h",
      remainingPercent: 50,
      resetsAt: nonFinite
    )
    #expect(!badResets.isValid)
  }

  @Test
  func enforcesCostAmountInvariants() throws {
    #expect(WidgetCost(status: .complete, amountMicrousd: "10").isValid)
    #expect(WidgetCost(status: .partial, amountMicrousd: "0").isValid)
    #expect(WidgetCost(status: .unavailable).isValid)

    #expect(!WidgetCost(status: .complete, amountMicrousd: nil).isValid)
    #expect(!WidgetCost(status: .partial, amountMicrousd: nil).isValid)
    #expect(!WidgetCost(status: .unavailable, amountMicrousd: "10").isValid)

    let completeMissingAmount = """
      {
        "version": 2,
        "fetched_at": "2026-08-14T16:00:00Z",
        "items": [],
        "today": {
          "input_tokens": 0,
          "output_tokens": 0,
          "cost": { "status": "complete" }
        }
      }
      """
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(completeMissingAmount)
    }

    let partialMissingAmount = """
      {
        "version": 2,
        "fetched_at": "2026-08-14T16:00:00Z",
        "items": [],
        "today": {
          "input_tokens": 0,
          "output_tokens": 0,
          "cost": { "status": "partial" }
        }
      }
      """
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(partialMissingAmount)
    }

    let unavailableWithAmount = """
      {
        "version": 2,
        "fetched_at": "2026-08-14T16:00:00Z",
        "items": [],
        "today": {
          "input_tokens": 0,
          "output_tokens": 0,
          "cost": { "status": "unavailable", "amount_microusd": "10" }
        }
      }
      """
    #expect(throws: DecodingError.self) {
      _ = try decodeSnapshot(unavailableWithAmount)
    }
  }

  @Test
  func loadRejectsOversizeWithoutReadingWholeFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = ProtectedFileWidgetSnapshotStore(directory: directory)
    // Write well beyond the load cap; load must reject after a bounded read.
    let oversize = Data(
      repeating: UInt8(ascii: "a"),
      count: ProtectedFileWidgetSnapshotStore.maximumLoadBytes * 4
    )
    try oversize.write(to: store.fileURL)
    #expect(throws: WidgetSnapshotStoreError.tooLarge) {
      _ = try store.load()
    }
  }

  private func makeSnapshot() -> WidgetSnapshot {
    WidgetSnapshot(
      fetchedAt: date("2026-08-14T16:00:00Z"),
      items: [
        WidgetQuotaItem(
          selectionID: "0123456789ab",
          providerID: "codex",
          providerDisplayName: "Codex",
          windowTitle: "5h",
          remainingPercent: 71.5,
          remainingValue: 42,
          unit: .usd,
          hasLimit: true,
          resetsAt: date("2026-08-14T21:00:00Z"),
          state: .available,
          validUntil: date("2026-08-14T21:00:00Z")
        ),
        WidgetQuotaItem(
          selectionID: "abcdef012345",
          providerID: "claude",
          providerDisplayName: "Claude Code",
          windowTitle: "Weekly",
          remainingPercent: 10
        ),
      ],
      today: WidgetTodayUsage(
        inputTokens: 1000,
        outputTokens: 200,
        cost: WidgetCost(status: .complete, amountMicrousd: "3138")
      )
    )
  }

  private func makeJSON(
    providerID: String,
    displayName: String,
    windowTitle: String,
    remainingPercent: Double = 50,
    selectionID: String = "0123456789ab"
  ) -> String {
    """
    {
      "version": 2,
      "fetched_at": "2026-08-14T16:00:00Z",
      "items": [{
        "selection_id": \(jsonString(selectionID)),
        "provider_id": \(jsonString(providerID)),
        "provider_display_name": \(jsonString(displayName)),
        "window_title": \(jsonString(windowTitle)),
        "remaining_percent": \(remainingPercent),
        "state": "available"
      }],
      "today": {
        "input_tokens": 0,
        "output_tokens": 0,
        "cost": { "status": "unavailable" }
      }
    }
    """
  }

  private func decodeSnapshot(_ json: String) throws -> WidgetSnapshot {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ProtectedFileWidgetSnapshotStore(directory: directory)
    try Data(json.utf8).write(to: store.fileURL)
    guard let snapshot = try store.load() else {
      throw WidgetSnapshotStoreError.tooLarge
    }
    return snapshot
  }

  private func encodeSnapshot(_ snapshot: WidgetSnapshot) throws -> Data {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ProtectedFileWidgetSnapshotStore(directory: directory)
    try store.save(snapshot)
    return try Data(contentsOf: store.fileURL)
  }

  private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
  }

  private func jsonString(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
    let wrapped = String(data: data, encoding: .utf8)!
    return String(wrapped.dropFirst().dropLast())
  }
}
