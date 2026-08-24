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
    case .stale: "Stale"
    case .signInNeeded: "Sign-in needed"
    case .unavailable: "Unavailable"
    case .unsupported: "Unsupported"
    case .failed: "Can’t refresh"
    }
  }
}

/// An observation that can answer whether it still describes current quota, and why not.
///
/// Two independent facts decide it. The source reports whether it could still read, which
/// it detects and publishes. The collecting device also stamps `valid_until` — the first
/// window reset it knows about, and at the latest a fixed age — which covers the case no
/// detection can: a device that stopped collecting entirely cannot report anything.
/// QuotaBar receives the verdict precomputed from the local service; the clients that read
/// an account observation directly conform their own type and ask it.
public protocol QuotaObservationFreshness {
  var reportedState: QuotaObservationState { get }
  var validUntil: Date? { get }
}

extension QuotaObservationFreshness {
  /// The state to show now: what the source reported, or aged out by its own stamp.
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
