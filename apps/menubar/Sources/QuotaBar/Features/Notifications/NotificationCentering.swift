import Foundation
import UserNotifications

/// The slice of `UNUserNotificationCenter` notification delivery and reset reminders talk to.
protocol NotificationCentering: AnyObject, Sendable {
  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
  func authorizationStatus() async -> UNAuthorizationStatus
  func add(_ request: UNNotificationRequest)
  func removePendingNotificationRequests(withIdentifiers identifiers: [String])
  func removeAllPendingNotificationRequests()
}

/// Production `UNUserNotificationCenter.current()`.
final class SystemNotificationCenter: NotificationCentering, @unchecked Sendable {
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    try await center.requestAuthorization(options: options)
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    await center.notificationSettings().authorizationStatus
  }

  func add(_ request: UNNotificationRequest) {
    center.add(request, withCompletionHandler: nil)
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
  }

  func removeAllPendingNotificationRequests() {
    center.removeAllPendingNotificationRequests()
  }
}

/// Tests that do not inject a center, and the visual-QA model, never talk to the system.
final class NoOpNotificationCenter: NotificationCentering, @unchecked Sendable {
  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { false }
  func authorizationStatus() async -> UNAuthorizationStatus { .notDetermined }
  func add(_ request: UNNotificationRequest) {}
  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
  func removeAllPendingNotificationRequests() {}
}
