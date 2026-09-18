import Foundation
import UserNotifications

/// The slice of `UNUserNotificationCenter` alert delivery and reset reminders talk to.
///
/// This slice does not request authorization. An `add` while unauthorized is silently
/// ineffective.
public protocol NotificationCentering: AnyObject, Sendable {
  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
  func authorizationStatus() async -> UNAuthorizationStatus
  func add(_ request: UNNotificationRequest)
  func removePendingNotificationRequests(withIdentifiers identifiers: [String])
  func removeAllPendingNotificationRequests()
}

/// Production `UNUserNotificationCenter.current()`.
///
/// An `add` uses `withCompletionHandler: nil` and reports nothing.
public final class SystemNotificationCenter: NotificationCentering, @unchecked Sendable {
  private let center: UNUserNotificationCenter

  public init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    try await center.requestAuthorization(options: options)
  }

  public func authorizationStatus() async -> UNAuthorizationStatus {
    await center.notificationSettings().authorizationStatus
  }

  public func add(_ request: UNNotificationRequest) {
    center.add(request, withCompletionHandler: nil)
  }

  public func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
  }

  public func removeAllPendingNotificationRequests() {
    center.removeAllPendingNotificationRequests()
  }
}

/// Tests that do not inject a center, and the visual-QA model, never talk to the system.
public final class NoOpNotificationCenter: NotificationCentering, @unchecked Sendable {
  public init() {}

  public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    false
  }

  public func authorizationStatus() async -> UNAuthorizationStatus { .notDetermined }
  public func add(_ request: UNNotificationRequest) {}
  public func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
  public func removeAllPendingNotificationRequests() {}
}
