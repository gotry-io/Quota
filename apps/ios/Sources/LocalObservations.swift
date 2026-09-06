import Foundation
import QuotaObservations
import QuotaWire

/// This iPhone as a source of readings.
///
/// It is the local side of the merge, and it stays that even once this phone is registered as a
/// Device and uploads what it read
/// ([ADR 0041](../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)): a reading
/// taken here is the authority for the device in front of you, whatever Relay later says about
/// the same Device.
enum ThisDevice {
  /// What every surface calls this phone's own readings.
  static let displayName = "This iPhone"

  /// The source identity a locally collected reading carries once it is projected back into a
  /// `QuotaSubscription`. It is the merge's own name for local collection, and Relay's device
  /// ids are opaque `device_…` ids, so it cannot be mistaken for one.
  static let sourceID = QuotaObservationOrigin.local.subscriptionSourceID
}

/// What this iPhone last read for itself.
///
/// It is kept beside the Account summary cache, in the app's own container rather than the App
/// Group: the widget reads the published snapshot and never a second data path
/// ([ADR 0014](../../../docs/decisions/0014-nonsecret-ios-widget-snapshot.md)).
struct LocalCollection: Codable, Equatable, Sendable {
  var collectedAt: Date
  var snapshots: [QuotaSnapshot]
  /// Sessions the provider refused. Settings offers those a fresh sign-in; a provider that could
  /// not be reached leaves no mark, because a network that was down says nothing about a session.
  var needsSignIn: [String]

  init(collectedAt: Date, snapshots: [QuotaSnapshot] = [], needsSignIn: [String] = []) {
    self.collectedAt = collectedAt
    self.snapshots = snapshots
    self.needsSignIn = needsSignIn
  }
}

protocol LocalCollectionStoring: Sendable {
  func load() throws -> LocalCollection?
  func save(_ value: LocalCollection) throws
  func clear() throws
}

/// The last local collection, in the app container beside the Account summary cache.
struct FileLocalCollectionStore: LocalCollectionStoring {
  let fileURL: URL

  init(directory: URL) {
    fileURL = directory.appendingPathComponent("local-observations.json", isDirectory: false)
  }

  static func applicationSupport() -> FileLocalCollectionStore? {
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
    return FileLocalCollectionStore(directory: directory)
  }

  func load() throws -> LocalCollection? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try WireCodec.decode(LocalCollection.self, from: Data(contentsOf: fileURL))
  }

  func save(_ value: LocalCollection) throws {
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

  func clear() throws {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    try FileManager.default.removeItem(at: fileURL)
  }
}

final class MemoryLocalCollectionStore: LocalCollectionStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var value: LocalCollection?

  init(value: LocalCollection? = nil) {
    self.value = value
  }

  func load() throws -> LocalCollection? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func save(_ value: LocalCollection) throws {
    lock.lock()
    self.value = value
    lock.unlock()
  }

  func clear() throws {
    lock.lock()
    value = nil
    lock.unlock()
  }
}

/// The one list of subscriptions this app shows.
///
/// The phone reads its own providers and the Account answers for every Mac, so Overview is two
/// readings of one subscription — exactly the comparison QuotaBar's service makes, and the same
/// rule: `QuotaObservations` states it, `quota-observation-conformance.json` judges it, and
/// nothing here restates it.
enum LocalObservationMerge {
  /// - Parameter selfDeviceID: the Device this phone's own session names, when it has one. What
  ///   this phone uploaded comes back as one of the Account's sources
  ///   ([ADR 0041](../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)); it is
  ///   already here as the local reading, so it is dropped rather than listed twice under two
  ///   names.
  static func subscriptions(
    local: [QuotaSnapshot],
    resolved: [QuotaSubscription],
    selfDeviceID: String? = nil,
    now: Date
  ) -> [QuotaSubscription] {
    let observations =
      local.map { QuotaObservation(origin: .local, snapshot: $0) }
      + resolved.compactMap { observation(from: $0, excluding: selfDeviceID, now: now) }
    return QuotaObservationMerge.merge(observations, now: now).map { merged in
      QuotaSubscription(
        key: merged.key,
        provider: merged.snapshot.provider,
        snapshot: merged.snapshot,
        sources: merged.sources.map { source in
          QuotaSubscriptionSource(
            deviceID: source.origin.subscriptionSourceID,
            observedAt: source.observedAt,
            snapshot: source.snapshot
          )
        }
      )
    }
  }

  /// A subscription Relay already resolved, attributed to the device whose reading it chose.
  /// The other devices stay attached and take no further part: Relay has already selected among
  /// them, and this phone only compares that answer against its own.
  ///
  /// When the reading Relay chose was this phone's own upload, the row is re-attributed to the
  /// newest device that is not this phone. What this phone read is not lost by that: it is the
  /// local observation the merge already holds.
  private static func observation(
    from subscription: QuotaSubscription,
    excluding selfDeviceID: String?,
    now: Date
  ) -> QuotaObservation<QuotaSnapshot>? {
    let others = subscription.sources.filter { $0.deviceID != selfDeviceID }
    let chosen =
      others
      .filter { $0.observedAt == subscription.snapshot.observedAt }
      .map(\.deviceID)
      .min()
      .map { (deviceID: $0, snapshot: subscription.snapshot) } ?? newest(of: others)
    // A row naming no device cannot be attributed to one, and inventing a source for it would
    // put a reading on screen under a device that never reported it.
    guard let chosen else { return nil }
    return QuotaObservation(
      origin: .device(id: chosen.deviceID),
      snapshot: chosen.snapshot,
      otherSources: others.compactMap { source in
        guard source.deviceID != chosen.deviceID else { return nil }
        return QuotaObservationSource(
          origin: .device(id: source.deviceID),
          observedAt: source.observedAt,
          isStale: source.snapshot?.isStale(now: now) ?? false,
          snapshot: source.snapshot
        )
      }
    )
  }

  /// The newest source that brought a reading of its own, ties broken by device id — the same
  /// order Relay resolved these with, applied to what is left after this phone is taken out.
  private static func newest(
    of sources: [QuotaSubscriptionSource]
  ) -> (deviceID: String, snapshot: QuotaSnapshot)? {
    var best: (deviceID: String, snapshot: QuotaSnapshot)?
    for source in sources {
      guard let snapshot = source.snapshot else { continue }
      guard let current = best else {
        best = (deviceID: source.deviceID, snapshot: snapshot)
        continue
      }
      let isNewer = snapshot.observedAt > current.snapshot.observedAt
      let ties =
        snapshot.observedAt == current.snapshot.observedAt && source.deviceID < current.deviceID
      if isNewer || ties {
        best = (deviceID: source.deviceID, snapshot: snapshot)
      }
    }
    return best
  }
}
