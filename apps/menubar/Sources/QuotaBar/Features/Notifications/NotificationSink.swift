/// Where evaluated notification events go. This build's sink is a no-op; delivery through
/// `UNUserNotificationCenter` replaces it later without changing the evaluator.
protocol NotificationSink: Sendable {
  func deliver(_ events: [NotificationEvent])
}

struct NoOpNotificationSink: NotificationSink {
  func deliver(_ events: [NotificationEvent]) {}
}
