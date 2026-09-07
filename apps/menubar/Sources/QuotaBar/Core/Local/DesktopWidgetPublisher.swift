import Foundation
import QuotaPresentation
import QuotaWidgetData
import QuotaWidgetProjection
import QuotaWire
import Security

/// What QuotaBar can say about the desktop widgets on the Diagnostics page. Publishing is never
/// allowed to interrupt a state update, so a failure is a sentence rather than an error.
enum DesktopWidgetPublishingStatus: Equatable, Sendable {
  /// This build is not entitled to the App Group, so there is nowhere to publish.
  case unentitled
  case published(itemCount: Int, at: Date)
  case cleared
  case failed(String)

  func message(now: Date = Date()) -> String {
    switch self {
    case .unentitled:
      return
        "Off. This build is not entitled to the App Group, so no snapshot is written."
    case .published(let itemCount, let at):
      let readings = itemCount == 1 ? "1 reading" : "\(itemCount) readings"
      return "\(readings) published, \(FreshnessCopy.updated(since: at, now: now).lowercased())."
    case .cleared:
      return "Nothing to publish, so the snapshot was cleared."
    case .failed(let reason):
      return "The last snapshot could not be written: \(reason)"
    }
  }
}

/// The 32-byte installation salt mixed into every widget `selection_id`, in QuotaBar's own
/// Keychain item rather than in the App Group the snapshot is published to
/// (`docs/decisions/0014-nonsecret-ios-widget-snapshot.md`).
struct DesktopSelectionSaltStore: Sendable {
  static let saltByteCount = 32
  static let service = "io.gotry.quotabar.selection-salt"
  static let account = "selection-salt"

  func loadOrCreate() throws -> Data {
    if let existing = try load() {
      return existing
    }
    var bytes = [UInt8](repeating: 0, count: Self.saltByteCount)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw DesktopWidgetPublishingError.saltUnavailable
    }
    let generated = Data(bytes)
    var attributes = Self.identity
    attributes[kSecValueData as String] = generated
    let added = SecItemAdd(attributes as CFDictionary, nil)
    if added == errSecSuccess {
      return generated
    }
    guard added == errSecDuplicateItem, let existing = try load() else {
      throw DesktopWidgetPublishingError.saltUnavailable
    }
    return existing
  }

  private func load() throws -> Data? {
    var query = Self.identity
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw DesktopWidgetPublishingError.saltUnavailable
    }
    return data
  }

  private static var identity: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

enum DesktopWidgetPublishingError: LocalizedError, Equatable {
  case saltUnavailable

  var errorDescription: String? {
    switch self {
    case .saltUnavailable: "the installation salt could not be read."
    }
  }
}

/// Publishes the Overview rows QuotaBar has already resolved into the App Group snapshot the
/// desktop widgets read, using the same projection Quota on iPhone publishes with.
@MainActor
final class DesktopWidgetPublisher {
  private let publisher: (any WidgetSnapshotPublishing)?
  /// Only a build with somewhere to publish ever asks the Keychain for the salt.
  private let loadSalt: () throws -> Data
  private(set) var status: DesktopWidgetPublishingStatus

  init(
    publisher: (any WidgetSnapshotPublishing)? = WidgetAppGroup.containerURL()
      .map { AppGroupWidgetSnapshotPublisher(containerURL: $0) },
    loadSalt: @escaping () throws -> Data = { try DesktopSelectionSaltStore().loadOrCreate() }
  ) {
    self.publisher = publisher
    self.loadSalt = loadSalt
    self.status = publisher == nil ? .unentitled : .cleared
  }

  /// Republished after every state update. An empty Overview publishes nothing and clears what
  /// the widgets were reading, so signing out or removing the last source empties them too.
  func publish(
    subscriptions: [DesktopWidgetSubscription],
    today: WidgetTodayUsage?,
    fetchedAt: Date
  ) {
    guard let publisher else { return }
    guard !subscriptions.isEmpty || today != nil else {
      clear()
      return
    }
    do {
      let salt = try loadSalt()
      let snapshot = WidgetSnapshotProjection.make(
        subscriptions: subscriptions.map { $0.projection(salt: salt) },
        today: today,
        fetchedAt: fetchedAt
      )
      try publisher.publish(snapshot)
      status = .published(itemCount: snapshot.items.count, at: fetchedAt)
    } catch {
      status = .failed(Self.reason(for: error))
    }
  }

  /// The row a widget deep link names, found by re-deriving the ids this installation published.
  /// A link from an older salt matches nothing, and the caller falls back to Overview.
  func subscription(
    forSelectionID selectionID: String,
    in subscriptions: [DesktopWidgetSubscription]
  ) -> DesktopWidgetSubscription? {
    guard let salt = try? loadSalt() else { return nil }
    return subscriptions.first {
      SelectionIDs.make(selector: $0.selector, salt: salt) == selectionID
    }
  }

  func clear() {
    guard let publisher else { return }
    do {
      try publisher.clear()
      status = .cleared
    } catch {
      status = .failed(Self.reason(for: error))
    }
  }

  private static func reason(for error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "\(error)"
  }
}

/// One Overview row on its way to the widget snapshot. `selector` is the unsalted
/// `provider|fingerprint|scope|source_id`; only its salted digest is published.
struct DesktopWidgetSubscription: Sendable {
  var snapshot: QuotaSnapshot
  var selector: String

  func projection(salt: Data) -> WidgetProjectionSubscription {
    WidgetProjectionSubscription(
      snapshot: snapshot,
      selectionID: SelectionIDs.make(selector: selector, salt: salt),
      sourceKey: selector
    )
  }
}
