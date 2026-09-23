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

  /// The fixture's `bucket` rule, or `nil` when `durationSeconds` is missing or not positive.
  ///
  /// `bucketStart` is `floor(observedAt / size) × size` in UTC, on `Date`'s `Double` seconds.
  /// The value is the maximum `usedPercent` in that bucket for that `resetsAt`. `lastUploaded`
  /// is the newest bucket per `resetsAt` already at Relay: a bucket with that same value is not
  /// returned, so the series ends at the last change. A bucket older than
  /// ``spanSeconds(durationSeconds:)`` is not returned. A `bucketStart` later than `now` is
  /// kept — the fixture includes those points. ``uploadable(_:durationSeconds:now:)`` is what
  /// drops the points Relay would refuse.
  public static func bucket(
    samples: [QuotaSample],
    durationSeconds: Int?,
    now: Date,
    lastUploaded: [Bucket]
  ) -> [Bucket]? {
    guard let durationSeconds, durationSeconds > 0 else { return nil }
    let cutoff = now.timeIntervalSince1970 - Double(spanSeconds(durationSeconds: durationSeconds))
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
      if bucketStart.timeIntervalSince1970 < cutoff { continue }
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

  /// The buckets Relay would accept: not older than the span plus one bucket, and not more
  /// than one bucket ahead of `now`. Exactly one bucket ahead, and exactly the slack edge,
  /// stay. Call this before every upload.
  public static func uploadable(
    _ buckets: [Bucket],
    durationSeconds: Int,
    now: Date
  ) -> [Bucket] {
    guard durationSeconds > 0 else { return [] }
    let size = Double(bucketSeconds(durationSeconds: durationSeconds))
    let span = Double(spanSeconds(durationSeconds: durationSeconds))
    let earliest = now.timeIntervalSince1970 - span - size
    let latest = now.timeIntervalSince1970 + size
    return buckets.filter { bucket in
      let start = bucket.bucketStart.timeIntervalSince1970
      return start >= earliest && start <= latest
    }
  }

  /// How long before its expiry a bucket stops counting as one Relay must still hold. Relay
  /// never sweeps a row before its `expires_at`, but a device clock behind Relay's, or an
  /// `expires_at` another device shortened by declaring a shorter duration, can make a row go
  /// earlier than this device expects.
  public static let oldestSlackSeconds = 3_600

  /// Relay must still hold this bucket: `bucket + span > now + 1 h`.
  public static func oldestIsLive(_ bucketStart: Date, durationSeconds: Int, now: Date) -> Bool {
    let span = Double(spanSeconds(durationSeconds: durationSeconds))
    return bucketStart.timeIntervalSince1970 + span
      > now.timeIntervalSince1970 + Double(oldestSlackSeconds)
  }

  /// What the upload answer says about one series the upload sent.
  public enum UploadAnswer: Equatable, Sendable {
    /// The answer leaves the series out.
    case absent
    /// Its `oldest_bucket_start`, or `nil` from a Relay that does not send one.
    case oldest(Date?)
  }

  /// Relay lost rows of a series this device uploaded (ADR 0062, amendment 2026-09-23).
  ///
  /// The evidence is the oldest bucket uploaded in this on-period while it is live, otherwise
  /// the watermark from before this chunk while it is live and every point of the chunk is
  /// later than it. A series the answer leaves out is always a loss: the answer names every
  /// series sent. No `oldest_bucket_start` (an older Relay) judges nothing. The fixture's
  /// `rows_lost` section is the contract.
  public static func rowsLost(
    recordedOldest: Date?,
    watermark: Date?,
    chunkOldest: Date,
    answer: UploadAnswer,
    durationSeconds: Int,
    now: Date
  ) -> Bool {
    let answered: Date
    switch answer {
    case .absent: return true
    case .oldest(nil): return false
    case .oldest(let value?): answered = value
    }
    let evidence: Date?
    if let recordedOldest,
      oldestIsLive(recordedOldest, durationSeconds: durationSeconds, now: now)
    {
      evidence = recordedOldest
    } else if let watermark,
      oldestIsLive(watermark, durationSeconds: durationSeconds, now: now),
      chunkOldest > watermark
    {
      evidence = watermark
    } else {
      evidence = nil
    }
    guard let evidence else { return false }
    return answered > evidence
  }

  /// The recorded oldest after an accepted chunk: the older of a live record and the chunk's
  /// oldest point, else the chunk's oldest point. The fixture's `reseed_oldest` section.
  public static func reseedOldest(
    _ recordedOldest: Date?,
    chunkOldest: Date,
    durationSeconds: Int,
    now: Date
  ) -> Date {
    if let recordedOldest,
      oldestIsLive(recordedOldest, durationSeconds: durationSeconds, now: now),
      recordedOldest <= chunkOldest
    {
      return recordedOldest
    }
    return chunkOldest
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
  let size = Double(QuotaHistorySync.bucketSeconds(durationSeconds: durationSeconds))
  let start = floor(observedAt.timeIntervalSince1970 / size) * size
  return Date(timeIntervalSince1970: start)
}

private func bucketIsBefore(
  _ lhs: QuotaHistorySync.Bucket,
  _ rhs: QuotaHistorySync.Bucket
) -> Bool {
  if lhs.resetsAt != rhs.resetsAt { return lhs.resetsAt < rhs.resetsAt }
  return lhs.bucketStart < rhs.bucketStart
}

private func saturatingMultiply(_ value: Int, by factor: Int) -> Int {
  let product = value.multipliedReportingOverflow(by: factor)
  if product.overflow { return value < 0 ? Int.min : Int.max }
  return product.partialValue
}
