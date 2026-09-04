import Foundation

/// One local notification the evaluator decided to fire.
enum NotificationEvent: Equatable, Sendable {
  case thresholdCrossed(
    selector: String,
    windowID: String,
    threshold: Int,
    remainingPercent: Double,
    resetsAt: Date?
  )
  case windowReset(selector: String, windowID: String, resetsAt: Date?)

  var selector: String {
    switch self {
    case .thresholdCrossed(let selector, _, _, _, _): selector
    case .windowReset(let selector, _, _): selector
    }
  }

  var windowID: String {
    switch self {
    case .thresholdCrossed(_, let windowID, _, _, _): windowID
    case .windowReset(_, let windowID, _): windowID
    }
  }

  var dedupKey: NotificationDedupKey {
    switch self {
    case .thresholdCrossed(let selector, let windowID, let threshold, _, let resetsAt):
      NotificationDedupKey(
        selector: selector, windowID: windowID, resetsAt: resetsAt, threshold: threshold)
    case .windowReset(let selector, let windowID, let resetsAt):
      NotificationDedupKey(
        selector: selector, windowID: windowID, resetsAt: resetsAt, threshold: nil)
    }
  }
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

  /// `UNNotificationRequest.identifier` — the same string the scheduler and the sink use.
  var requestIdentifier: String {
    let reset = Self.dateToken(resetsAt)
    if let threshold {
      return "threshold:\(selector):\(windowID):\(reset):\(threshold)"
    }
    return "reset:\(selector):\(windowID):\(reset)"
  }

  /// Pending reset reminders for one window, regardless of which `resets_at` they were booked for.
  static func resetIdentifierPrefix(selector: String, windowID: String) -> String {
    "reset:\(selector):\(windowID):"
  }

  static func dateToken(_ date: Date?) -> String {
    guard let date else { return "none" }
    return String(Int(date.timeIntervalSince1970))
  }
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
