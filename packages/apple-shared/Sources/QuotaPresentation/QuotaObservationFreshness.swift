import Foundation

/// What a source last reported about its own reading.
///
/// A collecting device publishes this, so a failure it detects becomes a fact every other
/// client can show immediately instead of one they have to wait out.
public enum QuotaObservationState: Sendable, Equatable {
  case available
  case stale
  case signInNeeded
  case unavailable
  case unsupported
  case failed

  /// The word for this state. Whether it is worth showing is `stateLabel(now:)`'s answer,
  /// not this one's.
  ///
  /// These are the words the app already uses for a failure on this machine, because a
  /// source that cannot read is the same problem wherever it runs.
  public var label: String {
    switch self {
    case .available: "Available"
    case .stale: "Not current"
    case .signInNeeded: "Sign-in needed"
    case .unavailable: "Unavailable"
    case .unsupported: "Unsupported"
    case .failed: "Can’t refresh"
    }
  }
}

/// A window as freshness reads it: when it refills, or how often it does.
public struct QuotaObservationWindow: Equatable, Sendable {
  public let resetsAt: Date?
  public let durationSeconds: Int?

  public init(resetsAt: Date?, durationSeconds: Int?) {
    self.resetsAt = resetsAt
    self.durationSeconds = durationSeconds
  }
}

/// How long a reading speaks for the account it describes.
public enum QuotaObservationValidity {
  /// How long an observation may claim to describe current quota when its own windows say
  /// nothing shorter. A device that stops collecting must stop answering for a live account.
  public static let maximumAge: TimeInterval = 86_400

  /// The instant this reading stops describing current quota.
  ///
  /// The first window reset is the exact boundary: at it that window refills and the number
  /// the reading carries is wrong. Windows that report no reset fall back to their own
  /// cadence, and every observation ages out at ``maximumAge``. Every input is part of the
  /// reading, so whoever holds it derives the same answer without a collector having
  /// stamped one onto it.
  public static func validUntil(
    observedAt: Date,
    windows: some Sequence<QuotaObservationWindow>
  ) -> Date {
    let limit = observedAt.addingTimeInterval(maximumAge)
    var earliestReset: Date?
    var shortestCadence: Int?
    for window in windows {
      if let reset = window.resetsAt, reset > observedAt {
        earliestReset = min(earliestReset ?? reset, reset)
      }
      if let seconds = window.durationSeconds {
        shortestCadence = min(shortestCadence ?? seconds, seconds)
      }
    }
    let boundary =
      earliestReset ?? shortestCadence.map { observedAt.addingTimeInterval(TimeInterval($0)) }
    guard let boundary else { return limit }
    return min(boundary, limit)
  }
}

/// An observation that can answer whether it still describes current quota, and why not.
///
/// Two independent facts decide it. The source reports whether it could still read, which
/// it detects and publishes. The reading also carries its own validity boundary — the first
/// window reset it reports, and at the latest a fixed age — which covers the case no
/// detection can: a device that stopped collecting entirely cannot report anything. An
/// observation derives that boundary with ``QuotaObservationValidity``; a published
/// snapshot that no longer carries the windows keeps the derived instant instead.
public protocol QuotaObservationFreshness {
  var reportedState: QuotaObservationState { get }
  var validUntil: Date? { get }
}

extension QuotaObservationFreshness {
  /// The state to show now: what the source reported, or aged out by its own boundary.
  public func observedState(now: Date = Date()) -> QuotaObservationState {
    guard reportedState == .available else { return reportedState }
    guard let validUntil, validUntil <= now else { return .available }
    return .stale
  }

  public func isStale(now: Date = Date()) -> Bool {
    observedState(now: now) != .available
  }

  /// Why this reading is not current, or `nil` while it is.
  public func stateLabel(now: Date = Date()) -> String? {
    let state = observedState(now: now)
    return state == .available ? nil : state.label
  }
}
