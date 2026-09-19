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
///
/// The chart domain is the last visible span: `min(retention, max(24 hours, 4 × cadence))`,
/// ending at the window reset or at `now` when that is later so the estimate still fits.
/// A 5 Hour window is last 24 hours; Weekly is last 4 weeks; monthly is the 30-day retention.
public struct QuotaRemainingHistory: Equatable, Sendable {
  public let segments: [QuotaRemainingHistorySegment]
  /// ADR 0035's projected remaining at the running window's reset. `nil` when pace cannot
  /// answer, or when this device has no samples of the window on screen.
  public let estimate: QuotaRemainingHistoryPoint?
  /// Inclusive start of the visible span after clipping.
  public let spanStart: Date
  /// Right edge of the chart domain: the running window's reset, or `now` when later.
  public let spanEnd: Date
  /// VoiceOver phrase for the span, e.g. `last 24 hours`.
  public let spanDescription: String

  public init(
    segments: [QuotaRemainingHistorySegment],
    estimate: QuotaRemainingHistoryPoint?,
    spanStart: Date,
    spanEnd: Date,
    spanDescription: String
  ) {
    self.segments = segments
    self.estimate = estimate
    self.spanStart = spanStart
    self.spanEnd = spanEnd
    self.spanDescription = spanDescription
  }

  public var observedPoints: [QuotaRemainingHistoryPoint] {
    segments.flatMap(\.points)
  }

  /// X-axis domain for the labelled chart: the visible span, including the estimate end.
  public var chartDomain: ClosedRange<Date> {
    if spanStart < spanEnd { return spanStart...spanEnd }
    return spanStart.addingTimeInterval(-60)...spanEnd.addingTimeInterval(60)
  }

  /// Last span the chart draws, in seconds: `min(retention, max(24 hours, 4 × cadence))`.
  public static func visibleSpanSeconds(cadenceSeconds: Int) -> TimeInterval {
    let fourWindows = TimeInterval(cadenceSeconds) * 4
    let day: TimeInterval = 24 * 3_600
    let retention = TimeInterval(QuotaHistory.retentionDays) * 86_400
    return min(retention, max(day, fourWindows))
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
    let spanSeconds = visibleSpanSeconds(cadenceSeconds: seconds)
    let spanEnd = max(now, resetsAt)
    let spanStart = spanEnd.addingTimeInterval(-spanSeconds)
    let spanDescription = Self.spanDescription(spanSeconds: spanSeconds)

    let grouped = Dictionary(grouping: samples, by: \.resetsAt)
      .mapValues { $0.sorted { $0.observedAt < $1.observedAt } }
    let unclipped = grouped.keys.sorted().compactMap {
      groupReset -> QuotaRemainingHistorySegment? in
      guard let group = grouped[groupReset] else { return nil }
      let points = remainingPoints(group)
      guard !points.isEmpty else { return nil }
      return QuotaRemainingHistorySegment(resetsAt: groupReset, points: points)
    }
    guard !unclipped.isEmpty else { return nil }

    let estimate: QuotaRemainingHistoryPoint?
    if unclipped.contains(where: { $0.resetsAt == resetsAt }) {
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

    let segments = unclipped.compactMap { clip($0, toStart: spanStart) }
    guard !segments.isEmpty else { return nil }

    return QuotaRemainingHistory(
      segments: segments,
      estimate: estimate,
      spanStart: spanStart,
      spanEnd: spanEnd,
      spanDescription: spanDescription
    )
  }

  /// Phrase the chart summary and observed-remaining list use for the visible span.
  public static func spanDescription(spanSeconds: TimeInterval) -> String {
    let hour: TimeInterval = 3_600
    let day: TimeInterval = 86_400
    let week = 7 * day
    let weeks = (spanSeconds / week).rounded()
    if weeks >= 1, abs(spanSeconds - weeks * week) < 1 {
      return weeks == 1 ? "last 1 week" : "last \(Int(weeks)) weeks"
    }
    if abs(spanSeconds - 24 * hour) < 1 {
      return "last 24 hours"
    }
    let days = (spanSeconds / day).rounded()
    if days >= 1, abs(spanSeconds - days * day) < 1 {
      return days == 1 ? "last 24 hours" : "last \(Int(days)) days"
    }
    let hours = max(1, Int((spanSeconds / hour).rounded()))
    return hours == 1 ? "last 1 hour" : "last \(hours) hours"
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

  /// Drops a segment wholly before `spanStart`; clips a crossing segment at that instant.
  private static func clip(
    _ segment: QuotaRemainingHistorySegment,
    toStart spanStart: Date
  ) -> QuotaRemainingHistorySegment? {
    let points = segment.points
    guard let last = points.last, last.date >= spanStart else { return nil }
    guard let first = points.first else { return nil }
    if first.date >= spanStart {
      return segment
    }
    var clipped: [QuotaRemainingHistoryPoint] = []
    for index in points.indices {
      let point = points[index]
      if point.date < spanStart { continue }
      if clipped.isEmpty, index > 0 {
        let previous = points[index - 1]
        if previous.date < spanStart, point.date > spanStart {
          clipped.append(interpolate(from: previous, to: point, at: spanStart))
        }
      }
      clipped.append(point)
    }
    guard !clipped.isEmpty else { return nil }
    return QuotaRemainingHistorySegment(resetsAt: segment.resetsAt, points: clipped)
  }

  private static func interpolate(
    from previous: QuotaRemainingHistoryPoint,
    to next: QuotaRemainingHistoryPoint,
    at date: Date
  ) -> QuotaRemainingHistoryPoint {
    let total = next.date.timeIntervalSince(previous.date)
    let fraction = total > 0 ? date.timeIntervalSince(previous.date) / total : 0
    let remaining =
      previous.remainingPercent
      + (next.remainingPercent - previous.remainingPercent) * max(0, min(1, fraction))
    return QuotaRemainingHistoryPoint(
      date: date,
      remainingPercent: round(remaining, 2)
    )
  }

  private static func round(_ value: Double, _ decimals: Int) -> Double {
    let scale = pow(10.0, Double(decimals))
    return (value * scale).rounded() / scale
  }
}
