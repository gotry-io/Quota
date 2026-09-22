import Foundation

/// Stand-in for the shared history rules K2s owns (`QuotaHistorySync.swift`).
///
/// Delete this file when that implementation is on the branch. Call sites stay on the names in
/// `K2-API.md`.
public enum QuotaHistorySync {
  /// `min(30 d, max(48 h, 4 × duration))`. Five-hour → 48 h, weekly → 28 d, monthly → 30 d.
  public static func spanSeconds(durationSeconds: Int) -> Int {
    let maximum = 30 * 86_400
    let minimum = 48 * 3_600
    let scaled = durationSeconds > maximum / 4 ? maximum : durationSeconds * 4
    return min(maximum, max(minimum, scaled))
  }

  /// 900 s when the window is a day or shorter, otherwise 3 600 s.
  public static func bucketSeconds(durationSeconds: Int) -> Int {
    durationSeconds <= 86_400 ? 900 : 3_600
  }

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

  /// The fixture's `bucket` rule. `lastUploaded` is the newest bucket per `resetsAt` already at
  /// Relay. A negative duration is refused as an empty series: a producer must know its window.
  /// A `bucketStart` later than `now` is kept. ``uploadable(_:durationSeconds:now:)`` drops what
  /// Relay would refuse.
  public static func bucket(
    samples: [QuotaSample],
    durationSeconds: Int,
    now: Date,
    lastUploaded: [Bucket]
  ) -> [Bucket] {
    guard durationSeconds >= 0 else { return [] }
    let size = Double(bucketSeconds(durationSeconds: durationSeconds))
    let cutoff = now.timeIntervalSince1970 - Double(spanSeconds(durationSeconds: durationSeconds))
    var lastByReset: [Date: Bucket] = [:]
    for point in lastUploaded {
      if let current = lastByReset[point.resetsAt] {
        if point.bucketStart >= current.bucketStart { lastByReset[point.resetsAt] = point }
      } else {
        lastByReset[point.resetsAt] = point
      }
    }
    var buckets: [ResetBucket: Bucket] = [:]
    for sample in samples {
      let start = aligned(sample.observedAt, size: size)
      if start.timeIntervalSince1970 < cutoff { continue }
      let key = ResetBucket(resetsAt: sample.resetsAt, bucketStart: start)
      let point = Bucket(
        resetsAt: sample.resetsAt,
        bucketStart: start,
        usedPercent: sample.usedPercent
      )
      if let existing = buckets[key] {
        if sample.usedPercent > existing.usedPercent { buckets[key] = point }
      } else {
        buckets[key] = point
      }
    }
    let ordered = buckets.values.sorted { lhs, rhs in
      if lhs.resetsAt != rhs.resetsAt { return lhs.resetsAt < rhs.resetsAt }
      return lhs.bucketStart < rhs.bucketStart
    }
    var uploaded: [Bucket] = []
    for point in ordered {
      if let last = lastByReset[point.resetsAt], last.usedPercent == point.usedPercent {
        continue
      }
      uploaded.append(point)
      lastByReset[point.resetsAt] = point
    }
    return uploaded
  }

  /// The buckets Relay would accept: not older than the span plus one bucket, and not more
  /// than one bucket ahead of `now`. Exactly one bucket ahead, and exactly the slack edge,
  /// stay. Call this before every upload. One out-of-range point refuses the whole request.
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

  /// The fixture's `merge` rule: union, maximum per `(resetsAt, bucketStart)`, oldest first.
  public static func merge(_ devices: [[Bucket]]) -> [Bucket] {
    var merged: [ResetBucket: Bucket] = [:]
    for device in devices {
      for point in device {
        let key = ResetBucket(resetsAt: point.resetsAt, bucketStart: point.bucketStart)
        if let existing = merged[key] {
          if point.usedPercent > existing.usedPercent { merged[key] = point }
        } else {
          merged[key] = point
        }
      }
    }
    return merged.values.sorted { lhs, rhs in
      if lhs.resetsAt != rhs.resetsAt { return lhs.resetsAt < rhs.resetsAt }
      return lhs.bucketStart < rhs.bucketStart
    }
  }

  /// Buckets become samples (`observedAt = bucketStart`) so `QuotaRemainingHistory.fold` is
  /// unchanged.
  public static func samples(from buckets: [Bucket]) -> [QuotaSample] {
    buckets.map {
      QuotaSample(resetsAt: $0.resetsAt, observedAt: $0.bucketStart, usedPercent: $0.usedPercent)
    }
  }

  private static func aligned(_ instant: Date, size: Double) -> Date {
    let epoch = instant.timeIntervalSince1970
    return Date(timeIntervalSince1970: (epoch / size).rounded(.down) * size)
  }

  private struct ResetBucket: Hashable {
    var resetsAt: Date
    var bucketStart: Date
  }
}

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
