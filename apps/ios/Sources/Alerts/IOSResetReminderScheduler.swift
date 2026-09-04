import Foundation
import QuotaAlerts
import UserNotifications

/// Calendar reminders for each available subscription's primary windows.
///
/// When `resets_at` is in the future, one `UNCalendarNotificationTrigger` is booked. A later
/// reading replaces the previous request for that selector and window. Turning the master
/// switch or reset-reminders off, or signing out, removes every pending reminder. Background
/// app refresh is asked for no sooner than every thirty minutes; the calendar booking is
/// what fires at `resets_at` if that window has not landed yet.
final class IOSResetReminderScheduler: @unchecked Sendable {
  private let center: any NotificationCentering
  private let calendar: Calendar
  private var scheduledKeys: Set<String> = []

  init(center: any NotificationCentering, calendar: Calendar = .current) {
    self.center = center
    self.calendar = calendar
  }

  var scheduledResetKeys: Set<String> { scheduledKeys }

  func hasScheduledReset(selector: String, windowID: String) -> Bool {
    scheduledKeys.contains(IOSAlertSink.resetKey(selector: selector, windowID: windowID))
  }

  func removeAll() {
    center.removeAllPendingNotificationRequests()
    scheduledKeys.removeAll()
  }

  func reschedule(
    rules: AlertRules,
    subscriptions: [AlertSubscriptionReading],
    catalog: AlertDeliveryCatalog,
    now: Date
  ) {
    // Rebuild the whole pending set so a relaunch does not stack a second reminder for the
    // same window, and a switch-off or a vanished subscription drops its request.
    center.removeAllPendingNotificationRequests()
    scheduledKeys.removeAll()
    guard rules.enabled, rules.resetReminders else { return }

    for subscription in subscriptions where subscription.status == "available" {
      for window in AlertEvaluator.evaluatedWindows(in: subscription.windows) {
        guard let resetsAt = window.resetsAt, resetsAt > now else { continue }
        guard
          let windowTitle = catalog.windowTitle(
            selector: subscription.selector, windowID: window.id),
          let provider = catalog.providerDisplayName(selector: subscription.selector)
        else { continue }
        let key = AlertDedupKey(
          selector: subscription.selector,
          windowID: window.id,
          resetsAt: resetsAt,
          threshold: nil
        )
        let content = UNMutableNotificationContent()
        content.title = AlertCopy.title(
          providerDisplayName: provider, windowTitle: windowTitle)
        content.body = AlertCopy.resetBody(windowTitle: windowTitle)
        content.threadIdentifier = subscription.selector
        content.sound = .default
        var components = calendar.dateComponents(
          [.year, .month, .day, .hour, .minute, .second],
          from: resetsAt
        )
        components.calendar = calendar
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        center.add(
          UNNotificationRequest(
            identifier: key.requestIdentifier,
            content: content,
            trigger: trigger
          )
        )
        scheduledKeys.insert(
          IOSAlertSink.resetKey(selector: subscription.selector, windowID: window.id)
        )
      }
    }
  }
}
