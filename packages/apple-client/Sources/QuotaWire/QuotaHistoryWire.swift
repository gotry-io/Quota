import Foundation
import QuotaPresentation

/// `PUT /api/v6/device/quota-history`.
///
/// Keys are snake_case through `WireCodec`'s key strategy. Dates are `Date` values, which that
/// codec writes as RFC 3339 UTC whole seconds. `newestBucketStart` on the upload answer is the
/// JSON key `bucket_start`. Decode and encode with `WireCodec`, not a coder that skips key
/// conversion: these coding keys are the camelCase names that strategy produces.
///
/// An upload is a write, so a key the contract does not name is refused. A response is a read,
/// so a key this build does not name is ignored (ADR 0023, ADR 0062).
public struct QuotaHistoryUploadRequest: Codable, Equatable, Sendable {
  /// At most this many points in one body. A backfill is chunked, oldest first.
  public static let maximumPoints = 2_000
  /// At most this many bytes of body. Relay answers 413 past it.
  public static let maximumBytes = 256 * 1_024

  public let protocolVersion: Int
  public let generation: Int
  public let series: [Series]

  public init(
    generation: Int,
    series: [Series],
    protocolVersion: Int = WireCodec.managedDataProtocolVersion
  ) {
    self.protocolVersion = protocolVersion
    self.generation = generation
    self.series = series
  }

  public init(from decoder: any Decoder) throws {
    try rejectUnknownQuotaHistoryKeys(
      decoder,
      allowed: ["protocolVersion", "generation", "series"]
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    generation = try container.decode(Int.self, forKey: .generation)
    series = try container.decode([Series].self, forKey: .series)
    guard protocolVersion == WireCodec.managedDataProtocolVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .protocolVersion,
        in: container,
        debugDescription: "protocol_version must be \(WireCodec.managedDataProtocolVersion)."
      )
    }
    guard WireValidation.isSafePositive(generation) else {
      throw DecodingError.dataCorruptedError(
        forKey: .generation,
        in: container,
        debugDescription: "generation must be a positive safe integer."
      )
    }
    var points = 0
    for item in series {
      let (next, overflow) = points.addingReportingOverflow(item.points.count)
      guard !overflow, next <= Self.maximumPoints else {
        throw DecodingError.dataCorruptedError(
          forKey: .series,
          in: container,
          debugDescription: "At most \(Self.maximumPoints) points."
        )
      }
      points = next
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encode(generation, forKey: .generation)
    try container.encode(series, forKey: .series)
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case generation
    case series
  }

  /// One global-scope window. There is no `fingerprint_scope`: only global identities sync.
  public struct Series: Codable, Equatable, Sendable {
    public let provider: ProviderID
    public let fingerprint: String
    public let windowId: String
    public let durationSeconds: Int
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

    public init(from decoder: any Decoder) throws {
      try rejectUnknownQuotaHistoryKeys(
        decoder,
        allowed: ["provider", "fingerprint", "windowId", "durationSeconds", "points"]
      )
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let providerRaw = try container.decode(String.self, forKey: .provider)
      guard let provider = ProviderID(rawValue: providerRaw) else {
        throw DecodingError.dataCorruptedError(
          forKey: .provider,
          in: container,
          debugDescription: "provider must be a catalog id."
        )
      }
      fingerprint = try container.decode(String.self, forKey: .fingerprint)
      windowId = try container.decode(String.self, forKey: .windowId)
      durationSeconds = try container.decode(Int.self, forKey: .durationSeconds)
      let strictPoints = try container.decode([StrictPoint].self, forKey: .points)
      let decodedPoints = strictPoints.map(\.point)
      guard WireValidation.isOpaqueID(fingerprint) else {
        throw DecodingError.dataCorruptedError(
          forKey: .fingerprint,
          in: container,
          debugDescription: "fingerprint must be an opaque id."
        )
      }
      guard WireValidation.isBillingDimension(windowId) else {
        throw DecodingError.dataCorruptedError(
          forKey: .windowId,
          in: container,
          debugDescription: "window_id must be a billing dimension."
        )
      }
      guard WireValidation.isSafeNonnegative(durationSeconds) else {
        throw DecodingError.dataCorruptedError(
          forKey: .durationSeconds,
          in: container,
          debugDescription: "duration_seconds must be a nonnegative safe integer."
        )
      }
      let duration = durationSeconds
      let aligned = decodedPoints.allSatisfy {
        isAlignedQuotaHistoryBucket($0.bucketStart, duration)
      }
      guard aligned else {
        throw DecodingError.dataCorruptedError(
          forKey: .points,
          in: container,
          debugDescription: "bucket_start must be aligned to the window's bucket size."
        )
      }
      self.provider = provider
      self.points = decodedPoints
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(provider, forKey: .provider)
      try container.encode(fingerprint, forKey: .fingerprint)
      try container.encode(windowId, forKey: .windowId)
      try container.encode(durationSeconds, forKey: .durationSeconds)
      try container.encode(points, forKey: .points)
    }

    private enum CodingKeys: String, CodingKey {
      case provider
      case fingerprint
      case windowId
      case durationSeconds
      case points
    }
  }

  public struct Point: Codable, Equatable, Sendable {
    public let resetsAt: Date
    public let bucketStart: Date
    public let usedPercent: Double

    public init(resetsAt: Date, bucketStart: Date, usedPercent: Double) {
      self.resetsAt = resetsAt
      self.bucketStart = bucketStart
      self.usedPercent = usedPercent
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      resetsAt = try container.decode(Date.self, forKey: .resetsAt)
      bucketStart = try container.decode(Date.self, forKey: .bucketStart)
      usedPercent = try container.decode(Double.self, forKey: .usedPercent)
      guard usedPercent.isFinite, (0...100).contains(usedPercent) else {
        throw DecodingError.dataCorruptedError(
          forKey: .usedPercent,
          in: container,
          debugDescription: "used_percent must be finite and in 0…100."
        )
      }
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(resetsAt, forKey: .resetsAt)
      try container.encode(bucketStart, forKey: .bucketStart)
      try container.encode(usedPercent, forKey: .usedPercent)
    }

    private enum CodingKeys: String, CodingKey {
      case resetsAt
      case bucketStart
      case usedPercent
    }
  }
}

/// What `PUT /api/v6/device/quota-history` answers: the newest `bucket_start` now held per series.
///
/// The JSON key is `bucket_start`. The Swift name is `newestBucketStart`, so its coding key is
/// the camelCase `bucketStart` that `WireCodec` turns into `bucket_start`.
public struct QuotaHistoryUploadResponse: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let series: [SeriesWatermark]

  public init(
    series: [SeriesWatermark],
    protocolVersion: Int = WireCodec.managedDataProtocolVersion
  ) {
    self.protocolVersion = protocolVersion
    self.series = series
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    series = try container.decode([SeriesWatermark].self, forKey: .series)
    guard protocolVersion == WireCodec.managedDataProtocolVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .protocolVersion,
        in: container,
        debugDescription: "protocol_version must be \(WireCodec.managedDataProtocolVersion)."
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encode(series, forKey: .series)
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case series
  }

  public struct SeriesWatermark: Codable, Equatable, Sendable {
    public let provider: ProviderID
    public let fingerprint: String
    public let windowId: String
    public let newestBucketStart: Date?

    public init(
      provider: ProviderID,
      fingerprint: String,
      windowId: String,
      newestBucketStart: Date?
    ) {
      self.provider = provider
      self.fingerprint = fingerprint
      self.windowId = windowId
      self.newestBucketStart = newestBucketStart
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      provider = try quotaHistoryReadProvider(container, forKey: .provider)
      fingerprint = try quotaHistoryReadFingerprint(container, forKey: .fingerprint)
      windowId = try quotaHistoryReadWindowId(container, forKey: .windowId)
      newestBucketStart = try container.decodeIfPresent(Date.self, forKey: .newestBucketStart)
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(provider, forKey: .provider)
      try container.encode(fingerprint, forKey: .fingerprint)
      try container.encode(windowId, forKey: .windowId)
      try container.encodeIfPresent(newestBucketStart, forKey: .newestBucketStart)
    }

    private enum CodingKeys: String, CodingKey {
      case provider
      case fingerprint
      case windowId
      /// JSON `bucket_start`, after `WireCodec` converts snake_case.
      case newestBucketStart = "bucketStart"
    }
  }
}

/// What `GET /api/v6/account/quota-history` answers for one subscription.
///
/// `sync` false is an empty `windows` object. `windows` is keyed by `window_id`.
public struct QuotaHistoryReadResponse: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let sync: Bool
  public let windows: [String: Window]

  public init(
    sync: Bool,
    windows: [String: Window],
    protocolVersion: Int = WireCodec.managedDataProtocolVersion
  ) {
    self.protocolVersion = protocolVersion
    self.sync = sync
    self.windows = windows
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    sync = try container.decode(Bool.self, forKey: .sync)
    windows = try quotaHistoryWindows(container, forKey: .windows)
    guard protocolVersion == WireCodec.managedDataProtocolVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .protocolVersion,
        in: container,
        debugDescription: "protocol_version must be \(WireCodec.managedDataProtocolVersion)."
      )
    }
    for windowId in windows.keys {
      guard WireValidation.isBillingDimension(windowId) else {
        throw DecodingError.dataCorruptedError(
          forKey: .windows,
          in: container,
          debugDescription: "A window id must be a billing dimension."
        )
      }
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encode(sync, forKey: .sync)
    try container.encode(windows, forKey: .windows)
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case sync
    case windows
  }

  public typealias Point = QuotaHistoryUploadRequest.Point

  public struct Window: Codable, Equatable, Sendable {
    public let durationSeconds: Int
    public let points: [Point]

    public init(durationSeconds: Int, points: [Point]) {
      self.durationSeconds = durationSeconds
      self.points = points
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      durationSeconds = try container.decode(Int.self, forKey: .durationSeconds)
      points = try container.decode([Point].self, forKey: .points)
      guard WireValidation.isSafeNonnegative(durationSeconds) else {
        throw DecodingError.dataCorruptedError(
          forKey: .durationSeconds,
          in: container,
          debugDescription: "duration_seconds must be a nonnegative safe integer."
        )
      }
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(durationSeconds, forKey: .durationSeconds)
      try container.encode(points, forKey: .points)
    }

    private enum CodingKeys: String, CodingKey {
      case durationSeconds
      case points
    }
  }
}

/// Upload points refuse a key the contract does not name. The read reuses
/// ``QuotaHistoryUploadRequest/Point``, which ignores one.
private struct StrictPoint: Decodable {
  let point: QuotaHistoryUploadRequest.Point

  init(from decoder: any Decoder) throws {
    try rejectUnknownQuotaHistoryKeys(
      decoder,
      allowed: ["resetsAt", "bucketStart", "usedPercent"]
    )
    point = try QuotaHistoryUploadRequest.Point(from: decoder)
  }
}

private struct QuotaHistoryAnyKey: CodingKey {
  var stringValue: String
  var intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue: Int) {
    nil
  }
}

private func rejectUnknownQuotaHistoryKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
  let container = try decoder.container(keyedBy: QuotaHistoryAnyKey.self)
  for key in container.allKeys where !allowed.contains(key.stringValue) {
    throw DecodingError.dataCorruptedError(
      forKey: key,
      in: container,
      debugDescription: "A quota-history upload states only the keys the contract defines."
    )
  }
}

private func quotaHistoryReadProvider<Key: CodingKey>(
  _ container: KeyedDecodingContainer<Key>,
  forKey key: Key
) throws -> ProviderID {
  let raw = try container.decode(String.self, forKey: key)
  return ProviderID(rawValue: raw) ?? .unknown(raw)
}

private func quotaHistoryReadFingerprint<Key: CodingKey>(
  _ container: KeyedDecodingContainer<Key>,
  forKey key: Key
) throws -> String {
  let fingerprint = try container.decode(String.self, forKey: key)
  guard WireValidation.isOpaqueID(fingerprint) else {
    throw DecodingError.dataCorruptedError(
      forKey: key,
      in: container,
      debugDescription: "fingerprint must be an opaque id."
    )
  }
  return fingerprint
}

private func quotaHistoryReadWindowId<Key: CodingKey>(
  _ container: KeyedDecodingContainer<Key>,
  forKey key: Key
) throws -> String {
  let windowId = try container.decode(String.self, forKey: key)
  guard WireValidation.isBillingDimension(windowId) else {
    throw DecodingError.dataCorruptedError(
      forKey: key,
      in: container,
      debugDescription: "window_id must be a billing dimension."
    )
  }
  return windowId
}

/// `windows` is keyed by the wire's `window_id`. `convertFromSnakeCase` rewrites dictionary
/// keys on the macOS 14 / iOS 17 Foundation (SR-7180), so `"five_hour"` would arrive as
/// `"fiveHour"`. Newer Foundation leaves `[String: Decodable]` keys alone but still reports
/// the converted name from a keyed container. When those two views disagree, the dictionary
/// still has the raw id. When they agree and a key was camelCased, put the underscore back.
private func quotaHistoryWindows<Key: CodingKey>(
  _ container: KeyedDecodingContainer<Key>,
  forKey key: Key
) throws -> [String: QuotaHistoryReadResponse.Window] {
  let decoded = try container.decode(
    [String: QuotaHistoryReadResponse.Window].self,
    forKey: key
  )
  let nested = try container.nestedContainer(keyedBy: QuotaHistoryAnyKey.self, forKey: key)
  let containerKeys = Set(nested.allKeys.map(\.stringValue))
  guard containerKeys == Set(decoded.keys) else { return decoded }
  var restored: [String: QuotaHistoryReadResponse.Window] = [:]
  for (name, window) in decoded {
    restored[quotaHistorySnakeCaseKey(name)] = window
  }
  return restored
}

/// Inverse of `convertFromSnakeCase` for a key that strategy camelCased. A key with no
/// uppercase was not rewritten (`weekly`, or an id already read raw).
func quotaHistorySnakeCaseKey(_ key: String) -> String {
  guard key.contains(where: \.isUppercase) else { return key }
  var restored = ""
  for character in key {
    if character.isUppercase {
      restored.append("_")
      restored.append(contentsOf: character.lowercased())
    } else {
      restored.append(character)
    }
  }
  return restored
}

private func isAlignedQuotaHistoryBucket(_ bucketStart: Date, _ durationSeconds: Int) -> Bool {
  let sizeMs = Int64(QuotaHistorySync.bucketSeconds(durationSeconds: durationSeconds)) * 1_000
  guard sizeMs > 0 else { return false }
  let milliseconds = Int64((bucketStart.timeIntervalSince1970 * 1_000).rounded(.toNearestOrEven))
  return milliseconds % sizeMs == 0
}

extension QuotaHistoryUploadRequest {
  public var pointCount: Int {
    series.reduce(0) { $0 + $1.points.count }
  }
}

/// The wire's spelling of an instant outside a JSON body — the `since` query of the read.
public enum QuotaHistoryWireFormat {
  public static func rfc3339UTC(_ date: Date) -> String {
    let whole = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: whole)
  }
}
