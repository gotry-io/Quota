import Foundation
import QuotaPresentation

/// Which rule fired. One window can fire each of these once per reset cycle.
public enum AlertKind: String, Equatable, Hashable, Sendable, Codable {
  case threshold
  case reset
  case pace
  case budget
}

/// One local remaining-quota alert the evaluator decided to fire.
public enum AlertEvent: Equatable, Sendable {
  case thresholdCrossed(
    selector: String,
    windowID: String,
    threshold: Int,
    remainingPercent: Double,
    resetsAt: Date?
  )
  case windowReset(selector: String, windowID: String, resetsAt: Date?)
  /// This window's burn rate no longer lasts to its reset.
  case paceRunsOut(selector: String, windowID: String, pace: QuotaPace, resetsAt: Date?)
  /// A share of this month's budget has been spent. The window is the month it was spent in.
  case budgetCrossed(month: String, threshold: Int, budgetUSD: Decimal)

  public var selector: String {
    switch self {
    case .thresholdCrossed(let selector, _, _, _, _): selector
    case .windowReset(let selector, _, _): selector
    case .paceRunsOut(let selector, _, _, _): selector
    case .budgetCrossed: BudgetAlertEvaluator.selector
    }
  }

  public var windowID: String {
    switch self {
    case .thresholdCrossed(_, let windowID, _, _, _): windowID
    case .windowReset(_, let windowID, _): windowID
    case .paceRunsOut(_, let windowID, _, _): windowID
    case .budgetCrossed(let month, _, _): month
    }
  }

  public var dedupKey: AlertDedupKey {
    switch self {
    case .thresholdCrossed(let selector, let windowID, let threshold, _, let resetsAt):
      AlertDedupKey(
        kind: .threshold, selector: selector, windowID: windowID, resetsAt: resetsAt,
        threshold: threshold)
    case .windowReset(let selector, let windowID, let resetsAt):
      AlertDedupKey(
        kind: .reset, selector: selector, windowID: windowID, resetsAt: resetsAt, threshold: nil)
    case .paceRunsOut(let selector, let windowID, _, let resetsAt):
      AlertDedupKey(
        kind: .pace, selector: selector, windowID: windowID, resetsAt: resetsAt, threshold: nil)
    case .budgetCrossed(let month, let threshold, _):
      AlertDedupKey(
        kind: .budget,
        selector: BudgetAlertEvaluator.selector,
        windowID: month,
        resetsAt: nil,
        threshold: threshold)
    }
  }
}

/// The last available reading of one evaluated window, used to detect crossings and resets.
public struct AlertStoredReading: Equatable, Sendable {
  public var selector: String
  public var windowID: String
  public var remainingPercent: Double
  public var resetsAt: Date?

  public init(selector: String, windowID: String, remainingPercent: Double, resetsAt: Date?) {
    self.selector = selector
    self.windowID = windowID
    self.remainingPercent = remainingPercent
    self.resetsAt = resetsAt
  }
}

/// `(kind, selector, windowID, resetsAt ?? none, threshold?)` — one fire per reset cycle.
public struct AlertDedupKey: Equatable, Hashable, Sendable {
  public var kind: AlertKind
  public var selector: String
  public var windowID: String
  public var resetsAt: Date?
  public var threshold: Int?

  public init(
    kind: AlertKind,
    selector: String,
    windowID: String,
    resetsAt: Date?,
    threshold: Int?
  ) {
    self.kind = kind
    self.selector = selector
    self.windowID = windowID
    self.resetsAt = resetsAt
    self.threshold = threshold
  }

  /// `UNNotificationRequest.identifier` — the same string the scheduler and the sink use.
  public var requestIdentifier: String {
    let reset = Self.dateToken(resetsAt)
    guard let threshold else { return "\(kind.rawValue):\(selector):\(windowID):\(reset)" }
    return "\(kind.rawValue):\(selector):\(windowID):\(reset):\(threshold)"
  }

  /// Pending reset reminders for one window, regardless of which `resets_at` they were booked for.
  public static func resetIdentifierPrefix(selector: String, windowID: String) -> String {
    "reset:\(selector):\(windowID):"
  }

  public static func dateToken(_ date: Date?) -> String {
    guard let date else { return "none" }
    return String(Int(date.timeIntervalSince1970))
  }
}

/// Dedup keys already fired this cycle, plus the last available remaining percent per window.
public struct AlertDedupState: Equatable, Sendable {
  public var fired: [AlertDedupKey]
  public var readings: [AlertStoredReading]

  public static let empty = AlertDedupState(fired: [], readings: [])

  public init(fired: [AlertDedupKey], readings: [AlertStoredReading]) {
    self.fired = fired
    self.readings = readings
  }
}

public struct AlertEvaluation: Equatable, Sendable {
  public var events: [AlertEvent]
  public var state: AlertDedupState

  public init(events: [AlertEvent], state: AlertDedupState) {
    self.events = events
    self.state = state
  }
}

/// One subscription as the evaluator reads it: an opaque selector, a wire status, and windows.
public struct AlertSubscriptionReading: Equatable, Sendable {
  public var selector: String
  public var status: String
  public var windows: [AlertWindowReading]

  public init(selector: String, status: String, windows: [AlertWindowReading]) {
    self.selector = selector
    self.status = status
    self.windows = windows
  }
}

public struct AlertWindowReading: Equatable, Sendable {
  public var id: String
  public var title: String
  public var remainingPercent: Double
  public var resetsAt: Date?
  /// The window cadence, which is what turns a remaining percent into a rate.
  public var durationSeconds: Int?
  public var primaryCadence: String?

  public init(
    id: String,
    title: String,
    remainingPercent: Double,
    resetsAt: Date?,
    durationSeconds: Int? = nil,
    primaryCadence: String?
  ) {
    self.id = id
    self.title = title
    self.remainingPercent = remainingPercent
    self.resetsAt = resetsAt
    self.durationSeconds = durationSeconds
    self.primaryCadence = primaryCadence
  }

  /// This window as the pace rule reads it.
  public var paceReading: QuotaPaceReading {
    QuotaPaceReading(
      usedPercent: 100 - remainingPercent,
      resetsAt: resetsAt,
      cadenceSeconds: durationSeconds,
      isBalanceOnly: false
    )
  }
}

extension AlertDedupState {
  public func sorted() -> AlertDedupState {
    AlertDedupState(
      fired: fired.sorted { lhs, rhs in
        if lhs.selector != rhs.selector { return lhs.selector < rhs.selector }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
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
