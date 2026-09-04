import Foundation
import QuotaAlerts

protocol AlertSink: Sendable {
  func deliver(_ events: [AlertEvent])
}

struct NoOpAlertSink: AlertSink {
  func deliver(_ events: [AlertEvent]) {}
}
