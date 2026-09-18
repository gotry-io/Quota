import Foundation
import QuotaAlerts
import UserNotifications

/// Where evaluated alert events go.
public protocol AlertSink: Sendable {
  func deliver(_ events: [AlertEvent])
}

public struct NoOpAlertSink: AlertSink {
  public init() {}

  public func deliver(_ events: [AlertEvent]) {}
}

/// Immediate `UNUserNotificationCenter` delivery. A `windowReset` whose selector and window
/// already have a scheduled reminder is left to that reminder rather than posted twice.
public final class UserNotificationAlertSink: AlertSink, @unchecked Sendable {
  private let center: any NotificationCentering
  public var catalog = AlertDeliveryCatalog.empty
  /// `"selector\u{1e}windowID"` keys the scheduler currently has a reminder for.
  public var scheduledResetKeys: Set<String> = []
  public var now: Date = Date()
  public var timeZone: TimeZone = .current
  public var calendar: Calendar = .current

  public init(center: any NotificationCentering) {
    self.center = center
  }

  public func deliver(_ events: [AlertEvent]) {
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

  public static func resetKey(selector: String, windowID: String) -> String {
    "\(selector)\u{1e}\(windowID)"
  }

  private func request(for event: AlertEvent) -> UNNotificationRequest? {
    let content = UNMutableNotificationContent()
    content.threadIdentifier = event.selector
    content.sound = .default
    if case .budgetCrossed(_, let threshold, let budgetUSD) = event {
      content.title = AlertCopy.budgetTitle
      content.body = AlertCopy.budgetBody(threshold: threshold, budgetUSD: budgetUSD)
      return UNNotificationRequest(
        identifier: event.dedupKey.requestIdentifier,
        content: content,
        trigger: nil
      )
    }
    guard let windowTitle = catalog.windowTitle(selector: event.selector, windowID: event.windowID)
    else { return nil }
    switch event {
    case .thresholdCrossed(_, _, _, let remainingPercent, let resetsAt):
      guard let provider = catalog.providerDisplayName(selector: event.selector) else { return nil }
      content.title = AlertCopy.title(
        providerDisplayName: provider, windowTitle: windowTitle)
      content.body = AlertCopy.thresholdBody(
        remainingPercent: remainingPercent,
        resetsAt: resetsAt,
        now: now,
        timeZone: timeZone,
        calendar: calendar
      )
    case .windowReset:
      guard let provider = catalog.providerDisplayName(selector: event.selector) else { return nil }
      content.title = AlertCopy.title(
        providerDisplayName: provider, windowTitle: windowTitle)
      content.body = AlertCopy.resetBody(windowTitle: windowTitle)
    case .paceRunsOut(_, _, let pace, let resetsAt):
      guard let provider = catalog.providerDisplayName(selector: event.selector),
        let body = AlertCopy.paceBody(pace: pace, resetsAt: resetsAt)
      else { return nil }
      content.title = AlertCopy.title(
        providerDisplayName: provider, windowTitle: windowTitle)
      content.body = body
    case .budgetCrossed:
      return nil
    }
    return UNNotificationRequest(
      identifier: event.dedupKey.requestIdentifier,
      content: content,
      trigger: nil
    )
  }
}
