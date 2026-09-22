import Foundation

/// How a device downsamples local remaining-quota samples, and how several devices' buckets
/// become one series. The rule is `packages/protocol/fixtures/quota-history-sync-conformance.json`
/// and [ADR 0062](../../../../docs/decisions/0062-quota-history-may-follow-the-account.md).
///
/// ``QuotaRemainingHistory/fold(window:samples:usedPercent:now:isBalanceOnly:)`` is unchanged.
/// ``samples(from:)`` is how a merged bucket becomes a sample that fold already accepts.
public enum QuotaHistorySync {
  /// `min(30 d, max(48 h, 4 × duration))`. Five-hour is 48 h, weekly is 28 d, monthly is 30 d.
  ///
  /// The chart draws a day less on the short side
  /// (``QuotaRemainingHistory/visibleSpanSeconds(cadenceSeconds:)`` uses 24 h), so a chart's
  /// left edge is never the retention edge.
  public static func spanSeconds(durationSeconds: Int) -> Int {
    let scaled = saturatingMultiply(durationSeconds, by: 4)
    return min(maxSpanSeconds, max(minSpanSeconds, scaled))
  }

  /// 900 s when `durationSeconds` is at most 86 400, otherwise 3 600 s.
  public static func bucketSeconds(durationSeconds: Int) -> Int {
    durationSeconds <= shortWindowMaxDurationSeconds ? shortBucketSeconds : longBucketSeconds
  }

  /// One uploaded or merged bucket. Not ``QuotaHistoryPoint``, which is a sparkline point.
  public struct Bucket: Codable, Equatable, Sendable {
    public let resetsAt: Date
    public let bucketStart: Date
    public let usedPercent: Double

    public init(resetsAt: Date, bucketStart: Date, usedPercent: Double) {
      self.resetsAt = resetsAt
      self.bucketStart = bucketStart
      self.usedPercent = usedPercent
    }
  }

  /// The fixture's `bucket` rule.
  ///
  /// `bucketStart` is `floor(observedAt / size) × size` in UTC. The value is the maximum
  /// `usedPercent` in that bucket for that `resetsAt`. `lastUploaded` is the newest bucket per
  /// `resetsAt` already at Relay: a bucket with that same value is not returned. A bucket older
  /// than ``spanSeconds(durationSeconds:)`` is not returned. A `bucketStart` later than `now` is
  /// kept — the fixture includes those points. Relay still refuses one more than a bucket ahead
  /// of its own clock.
  public static func bucket(
    samples: [QuotaSample],
    durationSeconds: Int,
    now: Date,
    lastUploaded: [Bucket]
  ) -> [Bucket] {
    let span = Int64(spanSeconds(durationSeconds: durationSeconds))
    let cutoff = epochMilliseconds(now) - span * 1_000
    var lastByReset: [Date: (bucketStart: Date, usedPercent: Double)] = [:]
    for point in lastUploaded {
      if let current = lastByReset[point.resetsAt], point.bucketStart < current.bucketStart {
        continue
      }
      lastByReset[point.resetsAt] = (point.bucketStart, point.usedPercent)
    }
    var buckets: [BucketKey: Bucket] = [:]
    for sample in samples {
      let bucketStart = bucketStart(sample.observedAt, durationSeconds: durationSeconds)
      if epochMilliseconds(bucketStart) < cutoff { continue }
      let key = BucketKey(resetsAt: sample.resetsAt, bucketStart: bucketStart)
      if let existing = buckets[key], sample.usedPercent <= existing.usedPercent { continue }
      buckets[key] = Bucket(
        resetsAt: sample.resetsAt,
        bucketStart: bucketStart,
        usedPercent: sample.usedPercent
      )
    }
    let ordered = buckets.values.sorted(by: bucketIsBefore)
    var uploaded: [Bucket] = []
    for point in ordered {
      if let last = lastByReset[point.resetsAt], last.usedPercent == point.usedPercent { continue }
      uploaded.append(point)
      lastByReset[point.resetsAt] = (point.bucketStart, point.usedPercent)
    }
    return uploaded
  }

  /// The fixture's `merge` rule: union, maximum `usedPercent` per `(resetsAt, bucketStart)`,
  /// oldest first.
  public static func merge(_ devices: [[Bucket]]) -> [Bucket] {
    var merged: [BucketKey: Bucket] = [:]
    for points in devices {
      for point in points {
        let key = BucketKey(resetsAt: point.resetsAt, bucketStart: point.bucketStart)
        if let existing = merged[key], point.usedPercent <= existing.usedPercent { continue }
        merged[key] = point
      }
    }
    return merged.values.sorted(by: bucketIsBefore)
  }

  /// Buckets become samples (`observedAt` = `bucketStart`) so the existing fold is unchanged.
  public static func samples(from buckets: [Bucket]) -> [QuotaSample] {
    buckets.map { bucket in
      QuotaSample(
        resetsAt: bucket.resetsAt,
        observedAt: bucket.bucketStart,
        usedPercent: bucket.usedPercent
      )
    }
  }
}

/// Whose readings the remaining-history caption names.
public enum QuotaHistorySource: Sendable {
  case thisDevice
  case yourDevices
}

extension QuotaHistoryCopy {
  /// "This iPhone" / "This Mac" (`deviceNoun`), or "From your devices".
  public static func sourceCaption(_ source: QuotaHistorySource, deviceNoun: String) -> String {
    switch source {
    case .thisDevice: deviceNoun
    case .yourDevices: "From your devices"
    }
  }
}

private let shortBucketSeconds = 900
private let longBucketSeconds = 3_600
private let shortWindowMaxDurationSeconds = 86_400
private let minSpanSeconds = 48 * 3_600
private let maxSpanSeconds = 30 * 86_400

private struct BucketKey: Hashable {
  let resetsAt: Date
  let bucketStart: Date
}

private func bucketStart(_ observedAt: Date, durationSeconds: Int) -> Date {
  let sizeMs = Int64(QuotaHistorySync.bucketSeconds(durationSeconds: durationSeconds)) * 1_000
  let startMs = floorDivide(epochMilliseconds(observedAt), by: sizeMs) * sizeMs
  return Date(timeIntervalSince1970: Double(startMs) / 1_000)
}

private func bucketIsBefore(
  _ lhs: QuotaHistorySync.Bucket,
  _ rhs: QuotaHistorySync.Bucket
) -> Bool {
  if lhs.resetsAt != rhs.resetsAt { return lhs.resetsAt < rhs.resetsAt }
  return lhs.bucketStart < rhs.bucketStart
}

private func epochMilliseconds(_ date: Date) -> Int64 {
  Int64((date.timeIntervalSince1970 * 1_000).rounded(.toNearestOrEven))
}

private func floorDivide(_ value: Int64, by divisor: Int64) -> Int64 {
  let quotient = value / divisor
  let remainder = value % divisor
  if remainder != 0 && value < 0 { return quotient - 1 }
  return quotient
}

private func saturatingMultiply(_ value: Int, by factor: Int) -> Int {
  let product = value.multipliedReportingOverflow(by: factor)
  if product.overflow { return value < 0 ? Int.min : Int.max }
  return product.partialValue
}
