import Foundation

/// RFC 3339 UTC, whole seconds, the spelling quota-history instants use on the wire.
public enum QuotaHistoryWireFormat {
  public static func rfc3339UTC(_ date: Date) -> String {
    let whole = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: whole)
  }
}

/// `PUT /api/v6/device/quota-history`. At most 2 000 points and 256 KiB.
public struct QuotaHistoryUploadRequest: Codable, Equatable, Sendable {
  public static let maximumPoints = 2_000
  public static let maximumBytes = 256 * 1_024

  public var protocolVersion: Int
  public var generation: Int
  public var series: [Series]

  public init(
    protocolVersion: Int = WireCodec.managedDataProtocolVersion,
    generation: Int,
    series: [Series]
  ) {
    self.protocolVersion = protocolVersion
    self.generation = generation
    self.series = series
  }

  public var pointCount: Int {
    series.reduce(0) { $0 + $1.points.count }
  }

  public struct Series: Codable, Equatable, Sendable {
    public var provider: ProviderID
    public var fingerprint: String
    public var windowId: String
    public var durationSeconds: Int
    public var points: [Point]

    public init(
      provider: ProviderID,
      fingerprint: String,
      windowId: String,
      durationSeconds: Int,
      points: [Point]
    ) {
      self.provider = provider
      self.fingerprint = fingerprint
      self.windowId = windowId
      self.durationSeconds = durationSeconds
      self.points = points
    }
  }

  public struct Point: Codable, Equatable, Sendable {
    public var resetsAt: Date
    public var bucketStart: Date
    public var usedPercent: Double

    public init(resetsAt: Date, bucketStart: Date, usedPercent: Double) {
      self.resetsAt = resetsAt
      self.bucketStart = bucketStart
      self.usedPercent = usedPercent
    }
  }
}

/// The newest `bucket_start` Relay now holds per series. The wire field is `bucket_start`;
/// `newestBucketStart` is the name callers use.
public struct QuotaHistoryUploadResponse: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var series: [SeriesWatermark]

  public init(
    protocolVersion: Int = WireCodec.managedDataProtocolVersion,
    series: [SeriesWatermark]
  ) {
    self.protocolVersion = protocolVersion
    self.series = series
  }

  public struct SeriesWatermark: Codable, Equatable, Sendable {
    public var provider: ProviderID
    public var fingerprint: String
    public var windowId: String
    public var newestBucketStart: Date

    public init(
      provider: ProviderID,
      fingerprint: String,
      windowId: String,
      newestBucketStart: Date
    ) {
      self.provider = provider
      self.fingerprint = fingerprint
      self.windowId = windowId
      self.newestBucketStart = newestBucketStart
    }

    private enum CodingKeys: String, CodingKey {
      case provider
      case fingerprint
      case windowId
      case newestBucketStart = "bucketStart"
    }
  }
}

/// `GET /api/v6/account/quota-history`. One global-scope subscription.
public struct QuotaHistoryReadResponse: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var sync: Bool
  public var windows: [String: Window]

  public init(
    protocolVersion: Int = WireCodec.managedDataProtocolVersion,
    sync: Bool,
    windows: [String: Window]
  ) {
    self.protocolVersion = protocolVersion
    self.sync = sync
    self.windows = windows
  }

  public struct Window: Codable, Equatable, Sendable {
    public var durationSeconds: Int
    public var points: [Point]

    public init(durationSeconds: Int, points: [Point]) {
      self.durationSeconds = durationSeconds
      self.points = points
    }
  }

  public struct Point: Codable, Equatable, Sendable {
    public var resetsAt: Date
    public var bucketStart: Date
    public var usedPercent: Double

    public init(resetsAt: Date, bucketStart: Date, usedPercent: Double) {
      self.resetsAt = resetsAt
      self.bucketStart = bucketStart
      self.usedPercent = usedPercent
    }
  }
}
