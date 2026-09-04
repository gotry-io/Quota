import AppIntents
import QuotaWidgetData
import WidgetKit

/// Widget configuration. `subscription == nil` is Automatic: the most constrained subscription.
struct OverviewWidgetIntent: WidgetConfigurationIntent {
  static var title: LocalizedStringResource { "Overview" }
  static var description: IntentDescription {
    IntentDescription("Remaining quota and Today Usage at a glance.")
  }

  @Parameter(title: "Subscription")
  var subscription: SubscriptionEntity?
}

/// One snapshot subscription. `id` is the locally salted `selection_id`; the display name is
/// `providerDisplayName · windowTitle` and never an account label.
struct SubscriptionEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Subscription" }
  static var defaultQuery: SubscriptionEntityQuery { SubscriptionEntityQuery() }

  var id: String
  var displayName: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: LocalizedStringResource(stringLiteral: displayName))
  }
}

/// Reads App Group snapshot candidates. Tests inject `loadSnapshot` so the extension's
/// file path is not required.
struct SubscriptionEntityQuery: EntityQuery {
  private let loadSnapshot: @Sendable () -> WidgetSnapshot?

  init() {
    self.init(loadSnapshot: { OverviewWidgetContent.loadSnapshot() })
  }

  init(loadSnapshot: @escaping @Sendable () -> WidgetSnapshot?) {
    self.loadSnapshot = loadSnapshot
  }

  func entities(for identifiers: [SubscriptionEntity.ID]) async throws -> [SubscriptionEntity] {
    let byID = Dictionary(
      uniqueKeysWithValues: Self.entities(from: loadSnapshot()).map { ($0.id, $0) }
    )
    return identifiers.compactMap { byID[$0] }
  }

  func suggestedEntities() async throws -> [SubscriptionEntity] {
    Self.entities(from: loadSnapshot())
  }

  func defaultResult() async -> SubscriptionEntity? {
    nil
  }

  /// One entity per `selection_id`, first window's provider · title, snapshot order.
  static func entities(from snapshot: WidgetSnapshot?) -> [SubscriptionEntity] {
    var seen = Set<String>()
    var result: [SubscriptionEntity] = []
    for item in snapshot?.items ?? [] {
      guard seen.insert(item.selectionID).inserted else { continue }
      result.append(
        SubscriptionEntity(
          id: item.selectionID,
          displayName: "\(item.providerDisplayName) · \(item.windowTitle)"
        )
      )
    }
    return result
  }
}
