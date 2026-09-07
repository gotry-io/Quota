import Foundation
import QuotaPresentation
import QuotaWire

/// What this iPhone has read of its own quota, over time.
///
/// One entry per provider and window id, oldest reading first. It is the phone's half of the
/// same decision QuotaBar's service keeps in `cache.sqlite`: samples belong to the device that
/// took them, are kept for thirty days, and are never uploaded
/// ([ADR 0042](../../../docs/decisions/0042-quota-history-is-local-samples.md)).
struct LocalQuotaSamples: Codable, Equatable, Sendable {
  /// One entry per provider and window id. A list rather than a keyed map because the wire
  /// codec renames keys between camelCase and `snake_case`, which a composite key would not
  /// survive.
  struct Entry: Codable, Equatable, Sendable {
    var provider: ProviderID
    var windowID: String
    var samples: [QuotaSample]
  }

  var windows: [Entry]

  init(windows: [Entry] = []) {
    self.windows = windows
  }

  func samples(provider: ProviderID, windowID: String) -> [QuotaSample] {
    windows.first { $0.provider == provider && $0.windowID == windowID }?.samples ?? []
  }

  /// Take one collection pass into the journal, then drop what has aged out.
  ///
  /// A window whose numbers have not moved since the last reading of the same window adds
  /// nothing to the curve, so it is not written again.
  mutating func record(_ snapshots: [QuotaSnapshot], now: Date) {
    for snapshot in snapshots {
      for window in snapshot.windows {
        guard let resetsAt = window.resetsAt else { continue }
        let index =
          windows.firstIndex {
            $0.provider == snapshot.provider && $0.windowID == window.id
          }
          ?? {
            windows.append(
              Entry(provider: snapshot.provider, windowID: window.id, samples: [])
            )
            return windows.count - 1
          }()
        var stored = windows[index].samples
        if stored.last(where: { $0.resetsAt == resetsAt })?.usedPercent == window.usedPercent {
          continue
        }
        stored.removeAll { $0.resetsAt == resetsAt && $0.observedAt == snapshot.observedAt }
        stored.append(
          QuotaSample(
            resetsAt: resetsAt,
            observedAt: snapshot.observedAt,
            usedPercent: window.usedPercent
          )
        )
        windows[index].samples = stored.sorted { $0.observedAt < $1.observedAt }
      }
    }
    prune(now: now)
  }

  mutating func prune(now: Date) {
    let horizon = now.addingTimeInterval(-Double(QuotaHistory.retentionDays) * 86_400)
    for index in windows.indices {
      windows[index].samples.removeAll { $0.observedAt < horizon }
    }
    windows.removeAll { $0.samples.isEmpty }
  }
}

protocol LocalQuotaSampleStoring: Sendable {
  func load() throws -> LocalQuotaSamples?
  func save(_ value: LocalQuotaSamples) throws
}

/// The sample journal, in the app's own container beside the last local collection.
struct FileLocalQuotaSampleStore: LocalQuotaSampleStoring {
  let fileURL: URL

  init(directory: URL) {
    fileURL = directory.appendingPathComponent("quota-samples.json", isDirectory: false)
  }

  static func applicationSupport() -> FileLocalQuotaSampleStore? {
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
    return FileLocalQuotaSampleStore(directory: directory)
  }

  func load() throws -> LocalQuotaSamples? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try WireCodec.decode(LocalQuotaSamples.self, from: Data(contentsOf: fileURL))
  }

  func save(_ value: LocalQuotaSamples) throws {
    let data = try WireCodec.encode(value)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(
      to: fileURL,
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    )
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = fileURL
    try? mutable.setResourceValues(values)
  }
}

final class MemoryLocalQuotaSampleStore: LocalQuotaSampleStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var value: LocalQuotaSamples?

  init(value: LocalQuotaSamples? = nil) {
    self.value = value
  }

  func load() throws -> LocalQuotaSamples? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func save(_ value: LocalQuotaSamples) throws {
    lock.lock()
    self.value = value
    lock.unlock()
  }
}
