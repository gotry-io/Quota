import AppIntents
import QuotaWidgetData
import WidgetKit

/// Widget configuration. `subscription == nil` is Automatic: the most constrained subscription.
public struct OverviewWidgetIntent: WidgetConfigurationIntent {
  public static var title: LocalizedStringResource { "Overview" }
  public static var description: IntentDescription {
    IntentDescription("Remaining quota, reset, and Today Usage at a glance.")
  }

  @Parameter(title: "Subscription")
  public var subscription: SubscriptionEntity?

  public init() {}
}

/// One snapshot subscription. `id` is the locally salted `selection_id`; the display name is
/// `providerDisplayName · windowTitle` and never an account label.
public struct SubscriptionEntity: AppEntity {
  public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Subscription" }
  public static var defaultQuery: SubscriptionEntityQuery { SubscriptionEntityQuery() }

  public var id: String
  public var displayName: String

  public init(id: String, displayName: String) {
    self.id = id
    self.displayName = displayName
  }

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: LocalizedStringResource(stringLiteral: displayName))
  }
}

/// Reads App Group snapshot candidates. Tests inject `loadSnapshot` so the extension's
/// file path is not required.
public struct SubscriptionEntityQuery: EntityQuery {
  private let loadSnapshot: @Sendable () -> WidgetSnapshot?

  public init() {
    self.init(loadSnapshot: { OverviewWidgetContent.loadSnapshot() })
  }

  public init(loadSnapshot: @escaping @Sendable () -> WidgetSnapshot?) {
    self.loadSnapshot = loadSnapshot
  }

  public func entities(for identifiers: [SubscriptionEntity.ID]) async throws -> [SubscriptionEntity] {
    let byID = Dictionary(
      uniqueKeysWithValues: Self.entities(from: loadSnapshot()).map { ($0.id, $0) }
    )
    return identifiers.compactMap { byID[$0] }
  }

  public func suggestedEntities() async throws -> [SubscriptionEntity] {
    Self.entities(from: loadSnapshot())
  }

  public func defaultResult() async -> SubscriptionEntity? {
    nil
  }

  /// One entity per `selection_id`, first window's provider · title, snapshot order.
  public static func entities(from snapshot: WidgetSnapshot?) -> [SubscriptionEntity] {
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
