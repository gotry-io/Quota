import Foundation

/// One remaining-percent reading on a history chart: either an observation this device took,
/// or the ADR 0035 estimate at reset.
public struct QuotaRemainingHistoryPoint: Equatable, Sendable {
  public let date: Date
  public let remainingPercent: Double
  public let isEstimate: Bool

  public init(date: Date, remainingPercent: Double, isEstimate: Bool = false) {
    self.date = date
    self.remainingPercent = remainingPercent
    self.isEstimate = isEstimate
  }
}

/// Observed remaining inside one `resetsAt`. A reset starts a new segment so the chart does
/// not draw a line up as if quota recovered.
public struct QuotaRemainingHistorySegment: Equatable, Sendable {
  public let resetsAt: Date
  public let points: [QuotaRemainingHistoryPoint]

  public init(resetsAt: Date, points: [QuotaRemainingHistoryPoint]) {
    self.resetsAt = resetsAt
    self.points = points
  }
}

/// Remaining 0–100 over calendar time for one window id, folded from the samples this device
/// kept (ADR 0042).
///
/// ``QuotaHistory/fold(window:samples:now:utcOffsetSeconds:)`` still answers the used-percent
/// sparkline of the running window. This fold is the labelled history chart: every sampled
/// reset cycle is a segment, a missing cycle stays a gap, and the dashed endpoint is the same
/// ADR 0035 projection the pace headline uses.
public struct QuotaRemainingHistory: Equatable, Sendable {
  public let segments: [QuotaRemainingHistorySegment]
  /// ADR 0035's projected remaining at the running window's reset. `nil` when pace cannot
  /// answer, or when this device has no samples of the window on screen.
  public let estimate: QuotaRemainingHistoryPoint?

  public init(
    segments: [QuotaRemainingHistorySegment],
    estimate: QuotaRemainingHistoryPoint?
  ) {
    self.segments = segments
    self.estimate = estimate
  }

  public var observedPoints: [QuotaRemainingHistoryPoint] {
    segments.flatMap(\.points)
  }

  /// - Parameters:
  ///   - usedPercent: the window on screen, so the dashed end agrees with the pace headline.
  ///   - isBalanceOnly: a wallet with no limit has no pace projection (ADR 0035).
  public static func fold(
    window: QuotaHistoryReading,
    samples: [QuotaSample],
    usedPercent: Double,
    now: Date,
    isBalanceOnly: Bool = false
  ) -> QuotaRemainingHistory? {
    guard let resetsAt = window.resetsAt, let seconds = window.cadenceSeconds, seconds > 0 else {
      return nil
    }
    let grouped = Dictionary(grouping: samples, by: \.resetsAt)
      .mapValues { $0.sorted { $0.observedAt < $1.observedAt } }
    let segments = grouped.keys.sorted().compactMap { groupReset -> QuotaRemainingHistorySegment? in
      guard let group = grouped[groupReset] else { return nil }
      let points = remainingPoints(group)
      guard !points.isEmpty else { return nil }
      return QuotaRemainingHistorySegment(resetsAt: groupReset, points: points)
    }
    guard !segments.isEmpty else { return nil }

    let estimate: QuotaRemainingHistoryPoint?
    if segments.contains(where: { $0.resetsAt == resetsAt }) {
      let pace = QuotaPace.evaluate(
        QuotaPaceReading(
          usedPercent: usedPercent,
          resetsAt: resetsAt,
          cadenceSeconds: seconds,
          isBalanceOnly: isBalanceOnly
        ),
        now: now
      )
      if let projected = pace.projection?.projectedAtReset {
        estimate = QuotaRemainingHistoryPoint(
          date: resetsAt,
          remainingPercent: RemainingQuotaFormat.remainingPercent(
            usedPercent: round(projected, 2)
          ),
          isEstimate: true
        )
      } else {
        estimate = nil
      }
    } else {
      estimate = nil
    }
    return QuotaRemainingHistory(segments: segments, estimate: estimate)
  }

  /// A window whose reset is missing from the samples is a gap: no segment, no connecting line.
  public static func hasGap(
    _ history: QuotaRemainingHistory,
    cadenceSeconds: Int
  ) -> Bool {
    guard cadenceSeconds > 0, history.segments.count >= 2 else { return false }
    let cadence = Double(cadenceSeconds)
    for (previous, next) in zip(history.segments, history.segments.dropFirst()) {
      if next.resetsAt.timeIntervalSince(previous.resetsAt) > cadence * 1.5 {
        return true
      }
    }
    return false
  }

  private static func remainingPoints(_ group: [QuotaSample]) -> [QuotaRemainingHistoryPoint] {
    QuotaHistory.keepDecimated(QuotaHistory.rising(group)).map { entry in
      QuotaRemainingHistoryPoint(
        date: entry.sample.observedAt,
        remainingPercent: RemainingQuotaFormat.remainingPercent(
          usedPercent: round(entry.usedPercent, 2)
        )
      )
    }
  }

  private static func round(_ value: Double, _ decimals: Int) -> Double {
    let scale = pow(10.0, Double(decimals))
    return (value * scale).rounded() / scale
  }
}
