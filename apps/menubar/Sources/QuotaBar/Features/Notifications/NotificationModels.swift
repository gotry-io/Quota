import Foundation

/// One local notification the evaluator decided to fire. Delivery is a later concern.
enum NotificationEvent: Equatable, Sendable {
  case thresholdCrossed(
    selector: String,
    windowID: String,
    threshold: Int,
    remainingPercent: Double,
    resetsAt: Date?
  )
  case windowReset(selector: String, windowID: String, resetsAt: Date?)
}

/// The last available reading of one evaluated window, used to detect crossings and resets.
struct NotificationStoredReading: Equatable, Sendable {
  var selector: String
  var windowID: String
  var remainingPercent: Double
  var resetsAt: Date?
}

/// `(selector, windowID, resetsAt ?? none, threshold?)` — one fire per reset cycle.
struct NotificationDedupKey: Equatable, Hashable, Sendable {
  var selector: String
  var windowID: String
  var resetsAt: Date?
  var threshold: Int?
}

/// Dedup keys already fired this cycle, plus the last available remaining percent per window.
struct NotificationDedupState: Equatable, Sendable {
  var fired: [NotificationDedupKey]
  var readings: [NotificationStoredReading]

  static let empty = NotificationDedupState(fired: [], readings: [])
}

struct NotificationEvaluation: Equatable, Sendable {
  var events: [NotificationEvent]
  var state: NotificationDedupState
}

/// One subscription as the evaluator reads it: an opaque selector, a wire status, and windows.
struct NotificationSubscriptionReading: Equatable, Sendable {
  var selector: String
  var status: String
  var windows: [NotificationWindowReading]
}

struct NotificationWindowReading: Equatable, Sendable {
  var id: String
  var title: String
  var remainingPercent: Double
  var resetsAt: Date?
  var primaryCadence: String?
}

extension NotificationDedupState {
  func sorted() -> NotificationDedupState {
    NotificationDedupState(
      fired: fired.sorted { lhs, rhs in
        if lhs.selector != rhs.selector { return lhs.selector < rhs.selector }
        if lhs.windowID != rhs.windowID { return lhs.windowID < rhs.windowID }
        switch (lhs.threshold, rhs.threshold) {
        case let (left?, right?) where left != right:
          return left < right
        case (nil, .some):
          return false
        case (.some, nil):
          return true
        default:
          break
        }
        switch (lhs.resetsAt, rhs.resetsAt) {
        case let (left?, right?):
          return left < right
        case (nil, .some):
          return true
        default:
          return false
        }
      },
      readings: readings.sorted { lhs, rhs in
        if lhs.selector != rhs.selector { return lhs.selector < rhs.selector }
        return lhs.windowID < rhs.windowID
      }
    )
  }
}
