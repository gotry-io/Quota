import Foundation

/// One reading of one window, kept by the device that took it.
///
/// Samples never leave that device: what a Mac or a phone saw of its own quota over time is
/// local state, not a managed contract. See ADR 0042.
public struct QuotaSample: Codable, Equatable, Sendable {
  public let resetsAt: Date
  public let observedAt: Date
  public let usedPercent: Double

  public init(resetsAt: Date, observedAt: Date, usedPercent: Double) {
    self.resetsAt = resetsAt
    self.observedAt = observedAt
    self.usedPercent = usedPercent
  }
}

/// One point of the curve a window draws: how far into the window it was taken, and how much
/// of the window was gone by then.
public struct QuotaHistoryPoint: Codable, Equatable, Sendable {
  public let elapsedFraction: Double
  public let usedPercent: Double

  public init(elapsedFraction: Double, usedPercent: Double) {
    self.elapsedFraction = elapsedFraction
    self.usedPercent = usedPercent
  }
}

/// One window of a window id that belongs to the reader's today.
public struct QuotaHistoryWindow: Codable, Equatable, Sendable {
  public let startedAt: Date
  public let resetsAt: Date
  public let peakUsedPercent: Double
  public let isCurrent: Bool

  public init(startedAt: Date, resetsAt: Date, peakUsedPercent: Double, isCurrent: Bool) {
    self.startedAt = startedAt
    self.resetsAt = resetsAt
    self.peakUsedPercent = peakUsedPercent
    self.isCurrent = isCurrent
  }
}

/// What a window's own samples say about it: the curve behind the reader, the dashed line to
/// the reset, and the windows the reader's day holds.
///
/// ``QuotaPace`` answers a window from one reading (ADR 0035); a curve needs more than one, so
/// the device that takes the readings keeps them and folds them here. QuotaBar is handed the
/// answer its Rust service derived; Quota iOS folds its own samples with this type. The rule is
/// stated once per runtime and `packages/protocol/fixtures/quota-history-conformance.json`
/// judges both. See ADR 0042.
public struct QuotaHistory: Codable, Equatable, Sendable {
  public let points: [QuotaHistoryPoint]
  /// ADR 0035's `projected_at_reset` over the last sample, stated at `elapsedFraction` 1.
  public let projection: QuotaHistoryPoint?
  public let windowsToday: [QuotaHistoryWindow]

  /// Two readings closer together than this say the same thing about the curve, so only the
  /// first of them becomes a point.
  public static let decimationSeconds: TimeInterval = 300

  /// How long a sample is worth keeping. A month covers every window cadence a provider states
  /// and every "what did yesterday look like" a reader asks, and stops there.
  public static let retentionDays = 30

  public init(
    points: [QuotaHistoryPoint],
    projection: QuotaHistoryPoint?,
    windowsToday: [QuotaHistoryWindow]
  ) {
    self.points = points
    self.projection = projection
    self.windowsToday = windowsToday
  }

  /// The history of one window, or `nil` when there is nothing to draw: no sample yet, or a
  /// window with no cadence to place its samples in.
  ///
  /// - Parameter utcOffsetSeconds: the reader's offset from UTC, which is what places a window
  ///   in their day rather than in the one UTC happens to be having.
  public static func fold(
    window: QuotaHistoryReading,
    samples: [QuotaSample],
    now: Date,
    utcOffsetSeconds: Int
  ) -> QuotaHistory? {
    guard let resetsAt = window.resetsAt, let seconds = window.cadenceSeconds, seconds > 0,
      !samples.isEmpty
    else {
      return nil
    }
    let cadence = Double(seconds)
    let grouped = Dictionary(grouping: samples, by: \.resetsAt)
      .mapValues { $0.sorted { $0.observedAt < $1.observedAt } }

    let current = grouped[resetsAt].map(rising)
    let points = current.map { curve($0, resetsAt: resetsAt, cadence: cadence) } ?? []
    let projection = current?.last.flatMap { last -> QuotaHistoryPoint? in
      let pace = QuotaPace.evaluate(
        QuotaPaceReading(
          usedPercent: last.usedPercent,
          resetsAt: resetsAt,
          cadenceSeconds: seconds,
          isBalanceOnly: false
        ),
        now: last.sample.observedAt
      )
      guard let projected = pace.projection?.projectedAtReset else { return nil }
      return QuotaHistoryPoint(elapsedFraction: 1, usedPercent: round(projected, 2))
    }

    let today = localDay(now, utcOffsetSeconds: utcOffsetSeconds)
    let windowsToday =
      grouped
      .filter { group in
        localDay(group.key, utcOffsetSeconds: utcOffsetSeconds) == today || group.key > now
      }
      .map { group in
        QuotaHistoryWindow(
          startedAt: group.key.addingTimeInterval(-cadence),
          resetsAt: group.key,
          peakUsedPercent: round(group.value.map(\.usedPercent).max() ?? 0, 2),
          isCurrent: group.key == resetsAt
        )
      }
      .sorted { $0.startedAt < $1.startedAt }

    guard !points.isEmpty || !windowsToday.isEmpty else { return nil }
    return QuotaHistory(points: points, projection: projection, windowsToday: windowsToday)
  }

  /// A window's samples with their used percent made non-decreasing.
  ///
  /// Inside one window a provider only ever spends, so a reading that came back lower is the
  /// provider disagreeing with itself; the curve keeps the higher number rather than dipping.
  private static func rising(
    _ group: [QuotaSample]
  ) -> [(sample: QuotaSample, usedPercent: Double)] {
    var peak = -Double.greatestFiniteMagnitude
    return group.map { sample in
      peak = max(peak, sample.usedPercent)
      return (sample, peak)
    }
  }

  /// The thinned curve: the first reading, one reading per decimation interval after it, and
  /// always the last, which is the point the reader is standing on.
  private static func curve(
    _ rising: [(sample: QuotaSample, usedPercent: Double)],
    resetsAt: Date,
    cadence: Double
  ) -> [QuotaHistoryPoint] {
    let windowStart = resetsAt.addingTimeInterval(-cadence)
    var kept: [(sample: QuotaSample, usedPercent: Double)] = []
    for entry in rising {
      guard let last = kept.last else {
        kept.append(entry)
        continue
      }
      if entry.sample.observedAt.timeIntervalSince(last.sample.observedAt) >= decimationSeconds {
        kept.append(entry)
      }
    }
    if let last = rising.last, kept.last?.sample.observedAt != last.sample.observedAt {
      kept.append(last)
    }
    return kept.map { entry in
      let elapsed = min(
        max(entry.sample.observedAt.timeIntervalSince(windowStart) / cadence, 0), 1)
      return QuotaHistoryPoint(
        elapsedFraction: round(elapsed, 4),
        usedPercent: round(entry.usedPercent, 2)
      )
    }
  }

  /// The reader's calendar day, as whole days at their offset from UTC.
  private static func localDay(_ instant: Date, utcOffsetSeconds: Int) -> Int {
    Int(((instant.timeIntervalSince1970 + Double(utcOffsetSeconds)) / 86_400).rounded(.down))
  }

  private static func round(_ value: Double, _ decimals: Int) -> Double {
    let scale = pow(10.0, Double(decimals))
    return (value * scale).rounded() / scale
  }
}

/// A window as history reads it: what places its samples in time.
public struct QuotaHistoryReading: Equatable, Sendable {
  public let resetsAt: Date?
  public let cadenceSeconds: Int?

  public init(resetsAt: Date?, cadenceSeconds: Int?) {
    self.resetsAt = resetsAt
    self.cadenceSeconds = cadenceSeconds
  }
}

/// The one line a provider group prints for the windows the reader's day holds.
///
/// `Today: 3 windows · 82% / 40% / 12%`, oldest first, and `nil` when the day holds none. The
/// phrase lives in `apps/menubar/DESIGN.md` Shared product vocabulary.
public enum QuotaHistoryCopy: Sendable {
  public static func todayLine(_ windows: [QuotaHistoryWindow]) -> String? {
    guard !windows.isEmpty else { return nil }
    let count = windows.count == 1 ? "1 window" : "\(windows.count) windows"
    let peaks = windows.map { peak($0.peakUsedPercent) }.joined(separator: " / ")
    return "Today: \(count) · \(peaks)"
  }

  public static func peak(_ usedPercent: Double) -> String {
    "\(Int(usedPercent.rounded()))%"
  }

  /// A window named by the local clock times it ran between, in the reader's own format.
  public static func span(_ window: QuotaHistoryWindow) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("jm")
    return "\(formatter.string(from: window.startedAt))–\(formatter.string(from: window.resetsAt))"
  }
}
