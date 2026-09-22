import Foundation
import QuotaPresentation
import QuotaWire

/// What this iPhone has read of its own quota, over time.
///
/// One entry per subscription and window id, oldest reading first. It is the phone's half of the
/// same decision QuotaBar's service keeps in `cache.sqlite`: samples belong to the device that
/// took them, are keyed by the local subscription selector, and are kept for thirty days. They
/// upload as downsampled buckets only while the Account's history switch is on
/// ([ADR 0042](../../../docs/decisions/0042-quota-history-is-local-samples.md),
/// [ADR 0062](../../../docs/decisions/0062-quota-history-may-follow-the-account.md)).
struct LocalQuotaSamples: Codable, Equatable, Sendable {
  /// Journal files written before this version have no subscription key and cannot be
  /// attributed, so they are discarded on load.
  static let schemaVersion = 1

  /// One entry per subscription and window id. A list rather than a keyed map because the wire
  /// codec renames keys between camelCase and `snake_case`, which a composite key would not
  /// survive.
  struct Entry: Codable, Equatable, Sendable {
    var subscriptionKey: String
    var provider: ProviderID
    var windowID: String
    var samples: [QuotaSample]
  }

  var schemaVersion: Int
  var windows: [Entry]

  init(windows: [Entry] = []) {
    self.schemaVersion = Self.schemaVersion
    self.windows = windows
  }

  func samples(for subscription: QuotaSubscription, windowID: String) -> [QuotaSample] {
    samples(subscriptionKey: Self.key(for: subscription), windowID: windowID)
  }

  func samples(subscriptionKey: String, windowID: String) -> [QuotaSample] {
    windows.first {
      $0.subscriptionKey == subscriptionKey && $0.windowID == windowID
    }?.samples ?? []
  }

  /// Take one collection pass into the journal, then drop what has aged out.
  ///
  /// A window whose numbers have not moved since the last reading of the same window adds
  /// nothing to the curve, so it is not written again. Each snapshot is stored under the
  /// subscription it belongs to, so two accounts of one provider keep separate histories.
  mutating func record(_ snapshots: [QuotaSnapshot], now: Date) {
    for snapshot in snapshots {
      let key = Self.key(for: snapshot)
      for window in snapshot.windows {
        guard let resetsAt = window.resetsAt else { continue }
        let index =
          windows.firstIndex {
            $0.subscriptionKey == key && $0.windowID == window.id
          }
          ?? {
            windows.append(
              Entry(
                subscriptionKey: key,
                provider: snapshot.provider,
                windowID: window.id,
                samples: []
              )
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

  /// The local opaque selector both clients already compute. Source-scoped snapshots collected
  /// on this phone use this device's source id.
  static func key(for snapshot: QuotaSnapshot) -> String {
    SubscriptionSelector.make(
      provider: snapshot.provider.rawValue,
      fingerprint: snapshot.account.fingerprint,
      fingerprintScope: snapshot.account.fingerprintScope.rawValue,
      sourceID: snapshot.account.fingerprintScope == .source ? ThisDevice.sourceID : nil
    )
  }

  static func key(for subscription: QuotaSubscription) -> String {
    SubscriptionSelector.make(
      provider: subscription.provider.rawValue,
      fingerprint: subscription.snapshot.account.fingerprint,
      fingerprintScope: subscription.snapshot.account.fingerprintScope.rawValue,
      sourceID: sourceID(fromKey: subscription.key)
    )
  }

  /// `provider|fingerprint|scope|source_id`; empty when the subscription is global.
  private static func sourceID(fromKey key: String) -> String? {
    let parts = key.split(separator: "|", omittingEmptySubsequences: false)
    guard parts.count >= 4, !parts[3].isEmpty else { return nil }
    return String(parts[3])
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
    let data = try Data(contentsOf: fileURL)
    guard let samples = try? WireCodec.decode(LocalQuotaSamples.self, from: data),
      samples.schemaVersion == LocalQuotaSamples.schemaVersion,
      samples.windows.allSatisfy({ !$0.subscriptionKey.isEmpty })
    else {
      try? FileManager.default.removeItem(at: fileURL)
      return nil
    }
    return samples
  }

  func save(_ value: LocalQuotaSamples) throws {
    var stored = value
    stored.schemaVersion = LocalQuotaSamples.schemaVersion
    let data = try WireCodec.encode(stored)
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
