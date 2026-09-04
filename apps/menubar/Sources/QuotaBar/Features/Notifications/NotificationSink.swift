import Foundation
import UserNotifications

/// Where evaluated notification events go.
protocol NotificationSink: Sendable {
  func deliver(_ events: [NotificationEvent])
}

struct NoOpNotificationSink: NotificationSink {
  func deliver(_ events: [NotificationEvent]) {}
}

/// Provider display names and window titles the sink needs to write `NotificationCopy`.
struct NotificationDeliveryCatalog: Equatable, Sendable {
  struct Entry: Equatable, Sendable {
    var providerDisplayName: String
    var windows: [String: String]
  }

  var entries: [String: Entry]

  static let empty = NotificationDeliveryCatalog(entries: [:])

  func providerDisplayName(selector: String) -> String? {
    entries[selector]?.providerDisplayName
  }

  func windowTitle(selector: String, windowID: String) -> String? {
    entries[selector]?.windows[windowID]
  }
}

/// Immediate `UNUserNotificationCenter` delivery. A `windowReset` whose selector and window
/// already have a scheduled reminder is left to that reminder rather than posted twice.
final class UserNotificationSink: NotificationSink, @unchecked Sendable {
  private let center: any NotificationCentering
  var catalog = NotificationDeliveryCatalog.empty
  /// `"selector\u{1e}windowID"` keys the scheduler currently has a reminder for.
  var scheduledResetKeys: Set<String> = []
  var now: Date = Date()
  var timeZone: TimeZone = .current
  var calendar: Calendar = .current

  init(center: any NotificationCentering) {
    self.center = center
  }

  func deliver(_ events: [NotificationEvent]) {
    for event in events {
      if case .windowReset(let selector, let windowID, _) = event,
        scheduledResetKeys.contains(Self.resetKey(selector: selector, windowID: windowID))
      {
        continue
      }
      guard let request = request(for: event) else { continue }
      center.add(request)
    }
  }

  static func resetKey(selector: String, windowID: String) -> String {
    "\(selector)\u{1e}\(windowID)"
  }

  private func request(for event: NotificationEvent) -> UNNotificationRequest? {
    guard let windowTitle = catalog.windowTitle(selector: event.selector, windowID: event.windowID)
    else { return nil }
    let content = UNMutableNotificationContent()
    content.threadIdentifier = event.selector
    content.sound = .default
    switch event {
    case .thresholdCrossed(_, _, _, let remainingPercent, let resetsAt):
      guard let provider = catalog.providerDisplayName(selector: event.selector) else { return nil }
      content.title = NotificationCopy.title(
        providerDisplayName: provider, windowTitle: windowTitle)
      content.body = NotificationCopy.thresholdBody(
        remainingPercent: remainingPercent,
        resetsAt: resetsAt,
        now: now,
        timeZone: timeZone,
        calendar: calendar
      )
    case .windowReset:
      guard let provider = catalog.providerDisplayName(selector: event.selector) else { return nil }
      content.title = NotificationCopy.title(
        providerDisplayName: provider, windowTitle: windowTitle)
      content.body = NotificationCopy.resetBody(windowTitle: windowTitle)
    }
    return UNNotificationRequest(
      identifier: event.dedupKey.requestIdentifier,
      content: content,
      trigger: nil
    )
  }
}
