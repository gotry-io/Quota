import Foundation
import QuotaAlerts
import QuotaPresentation
import QuotaWire

/// Overview rows as the evaluator, the sink, and the Notifications page read them.
enum NotificationOverview {
  static func selector(for item: LocalServiceOverviewItem) -> String {
    SubscriptionSelector.make(
      provider: item.identity.provider.rawValue,
      fingerprint: item.identity.fingerprint,
      fingerprintScope: item.identity.scope.rawValue,
      sourceID: item.identity.sourceID
    )
  }

  static func readings(
    from overview: [LocalServiceOverviewItem]
  ) -> [AlertSubscriptionReading] {
    overview.map { item in
      AlertSubscriptionReading(
        selector: selector(for: item),
        status: item.snapshot.status.rawValue,
        windows: item.snapshot.windows.compactMap { window in
          guard window.showsPercentMeter else { return nil }
          return AlertWindowReading(
            id: window.id,
            title: window.title,
            remainingPercent: window.remainingPercent,
            resetsAt: window.resetsAt,
            primaryCadence: window.primaryCadenceKind?.rawValue
          )
        }
      )
    }
  }

  static func catalog(
    from overview: [LocalServiceOverviewItem]
  ) -> NotificationDeliveryCatalog {
    var entries: [String: NotificationDeliveryCatalog.Entry] = [:]
    for item in overview {
      let windows = Dictionary(uniqueKeysWithValues: item.snapshot.windows.map { ($0.id, $0.title) })
      entries[selector(for: item)] = NotificationDeliveryCatalog.Entry(
        providerDisplayName: item.identity.provider.displayName,
        windows: windows
      )
    }
    return NotificationDeliveryCatalog(entries: entries)
  }
}

/// One Overview-visible subscription as the Notifications page lists it.
struct NotificationSettingsSubscription: Equatable, Identifiable, Sendable {
  var selector: String
  var provider: ProviderID
  var providerDisplayName: String
  var accountLabel: String
  var firstThreshold: Int
  var secondThreshold: Int?

  var id: String { selector }
}

enum NotificationsSettingsCopy {
  static let footer = "Quota reminds you when a refresh brings new data."
  static let permissionDenied =
    "Allow notifications for QuotaBar in System Settings."
  static let openSystemSettings = "Open System Settings"
  static let systemSettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
  static let alertAt = "Alert at"
  static let thenAt = "Then at"
  static let off = "Off"
  static let notificationsOn = "On"
  static let notificationsOff = "Off"

  static func thresholdLabel(_ value: Int) -> String {
    RemainingQuotaFormat.percent(Double(value))
  }

  static func homeTrailing(enabled: Bool) -> String {
    enabled ? notificationsOn : notificationsOff
  }
}
