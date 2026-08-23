import Foundation

/// An observation that can answer whether it still describes current quota.
///
/// The collecting device stamps `valid_until` on every snapshot it records and uploads:
/// the first window reset it knows about, and at the latest a fixed age. A reader that
/// ignored it would present a sleeping or signed-out device's counters as current
/// forever. QuotaBar receives this verdict precomputed from the local service; the
/// clients that read an account observation directly conform their own type and ask it.
public protocol QuotaObservationFreshness {
  /// Whether the source reported this as an available reading rather than a stale or
  /// failed one.
  var isAvailable: Bool { get }
  /// When the reading stops describing current quota, when the source stamped one.
  var validUntil: Date? { get }
}

extension QuotaObservationFreshness {
  public func isStale(now: Date = Date()) -> Bool {
    !isAvailable || validUntil.map { $0 <= now } ?? false
  }
}
