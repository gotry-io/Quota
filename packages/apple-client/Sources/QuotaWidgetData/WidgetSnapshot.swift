import Foundation
import QuotaPresentation

/// Versioned, bounded widget-facing quota projection. Foundation-only; no account/session fields.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
  /// 2 carries per-item freshness facts (`isAvailable`, `validUntil`) where 1 carried a
  /// published `isStale` verdict. A file written by the older shape is rejected by this
  /// gate and the app republishes.
  public static let currentVersion = 2
  public static let maximumItemCount = 16

  public let version: Int
  public let fetchedAt: Date
  public let items: [WidgetQuotaItem]
  public let today: WidgetTodayUsage

  public init(
    version: Int = currentVersion,
    fetchedAt: Date,
    items: [WidgetQuotaItem],
    today: WidgetTodayUsage
  ) {
    self.version = version
    self.fetchedAt = fetchedAt
    self.items = items
    self.today = today
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownKeys(["version", "fetchedAt", "items", "today"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
    items = try container.decode([WidgetQuotaItem].self, forKey: .items)
    today = try container.decode(WidgetTodayUsage.self, forKey: .today)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .version,
        in: container,
        debugDescription: "Invalid widget snapshot."
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    guard isValid else {
      throw EncodingError.invalidValue(
        self,
        EncodingError.Context(
          codingPath: encoder.codingPath,
          debugDescription: "Invalid widget snapshot."
        )
      )
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(fetchedAt, forKey: .fetchedAt)
    try container.encode(items, forKey: .items)
    try container.encode(today, forKey: .today)
  }

  public var isValid: Bool {
    version == Self.currentVersion
      && WidgetValidation.isFiniteDate(fetchedAt)
      && items.count <= Self.maximumItemCount
      && items.allSatisfy(\.isValid)
      && today.isValid
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case fetchedAt
    case items
    case today
  }
}

public enum WidgetQuotaUnit: String, Codable, Sendable, Equatable {
  case usd
  case credits
  case count
}

public struct WidgetQuotaItem: Codable, Equatable, Sendable {
  public static let maximumProviderIDLength = 64
  public static let maximumDisplayNameLength = 128
  public static let maximumWindowTitleLength = 128

  public let providerID: String
  public let providerDisplayName: String
  public let windowTitle: String
  public let remainingPercent: Double
  public let remainingValue: Double?
  public let unit: WidgetQuotaUnit?
  public let hasLimit: Bool?
  public let resetsAt: Date?
  /// The freshness facts, not a verdict: the widget re-renders on its own timeline, so it
  /// decides staleness at the instant it draws rather than at the instant it was written.
  public let isAvailable: Bool
  public let validUntil: Date?

  public init(
    providerID: String,
    providerDisplayName: String,
    windowTitle: String,
    remainingPercent: Double,
    remainingValue: Double? = nil,
    unit: WidgetQuotaUnit? = nil,
    hasLimit: Bool? = nil,
    resetsAt: Date? = nil,
    isAvailable: Bool = true,
    validUntil: Date? = nil
  ) {
    self.providerID = providerID
    self.providerDisplayName = providerDisplayName
    self.windowTitle = windowTitle
    self.remainingPercent = remainingPercent
    self.remainingValue = remainingValue
    self.unit = unit
    self.hasLimit = hasLimit
    self.resetsAt = resetsAt
    self.isAvailable = isAvailable
    self.validUntil = validUntil
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownKeys([
      "providerId", "providerDisplayName", "windowTitle", "remainingPercent", "remainingValue",
      "unit", "hasLimit", "resetsAt", "isAvailable", "validUntil",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    providerID = try container.decode(String.self, forKey: .providerID)
    providerDisplayName = try container.decode(String.self, forKey: .providerDisplayName)
    windowTitle = try container.decode(String.self, forKey: .windowTitle)
    remainingPercent = try container.decode(Double.self, forKey: .remainingPercent)
    remainingValue = try container.decodeIfPresent(Double.self, forKey: .remainingValue)
    unit = try container.decodeIfPresent(WidgetQuotaUnit.self, forKey: .unit)
    hasLimit = try container.decodeIfPresent(Bool.self, forKey: .hasLimit)
    resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
    isAvailable = try container.decode(Bool.self, forKey: .isAvailable)
    validUntil = try container.decodeIfPresent(Date.self, forKey: .validUntil)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .providerID,
        in: container,
        debugDescription: "Invalid widget quota item."
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    guard isValid else {
      throw EncodingError.invalidValue(
        self,
        EncodingError.Context(
          codingPath: encoder.codingPath,
          debugDescription: "Invalid widget quota item."
        )
      )
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(providerID, forKey: .providerID)
    try container.encode(providerDisplayName, forKey: .providerDisplayName)
    try container.encode(windowTitle, forKey: .windowTitle)
    try container.encode(remainingPercent, forKey: .remainingPercent)
    try container.encodeIfPresent(remainingValue, forKey: .remainingValue)
    try container.encodeIfPresent(unit, forKey: .unit)
    try container.encodeIfPresent(hasLimit, forKey: .hasLimit)
    try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
    try container.encode(isAvailable, forKey: .isAvailable)
    try container.encodeIfPresent(validUntil, forKey: .validUntil)
  }

  public var isValid: Bool {
    WidgetValidation.isTrimmedText(providerID, maximum: Self.maximumProviderIDLength)
      && WidgetValidation.isTrimmedText(
        providerDisplayName, maximum: Self.maximumDisplayNameLength)
      && WidgetValidation.isTrimmedText(windowTitle, maximum: Self.maximumWindowTitleLength)
      && remainingPercent.isFinite
      && (0...100).contains(remainingPercent)
      && (remainingValue?.isFinite ?? true)
      && (resetsAt.map(WidgetValidation.isFiniteDate) ?? true)
      && (validUntil.map(WidgetValidation.isFiniteDate) ?? true)
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "providerId"
    case providerDisplayName
    case windowTitle
    case remainingPercent
    case remainingValue
    case unit
    case hasLimit
    case resetsAt
    case isAvailable
    case validUntil
  }
}

extension WidgetQuotaItem: QuotaObservationFreshness {}

public struct WidgetTodayUsage: Codable, Equatable, Sendable {
  public let inputTokens: Int
  public let outputTokens: Int
  public let cost: WidgetCost

  public init(inputTokens: Int, outputTokens: Int, cost: WidgetCost) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cost = cost
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownKeys(["inputTokens", "outputTokens", "cost"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inputTokens = try container.decode(Int.self, forKey: .inputTokens)
    outputTokens = try container.decode(Int.self, forKey: .outputTokens)
    cost = try container.decode(WidgetCost.self, forKey: .cost)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .inputTokens,
        in: container,
        debugDescription: "Invalid widget today usage."
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    guard isValid else {
      throw EncodingError.invalidValue(
        self,
        EncodingError.Context(
          codingPath: encoder.codingPath,
          debugDescription: "Invalid widget today usage."
        )
      )
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(inputTokens, forKey: .inputTokens)
    try container.encode(outputTokens, forKey: .outputTokens)
    try container.encode(cost, forKey: .cost)
  }

  public var isValid: Bool {
    WidgetValidation.isSafeNonnegative(inputTokens)
      && WidgetValidation.isSafeNonnegative(outputTokens)
      && cost.isValid
  }

  private enum CodingKeys: String, CodingKey {
    case inputTokens
    case outputTokens
    case cost
  }
}

public enum WidgetCostStatus: String, Codable, Sendable, Equatable {
  case complete
  case partial
  case unavailable
}

public struct WidgetCost: Codable, Equatable, Sendable {
  public let status: WidgetCostStatus
  public let amountMicrousd: String?

  public init(status: WidgetCostStatus, amountMicrousd: String? = nil) {
    self.status = status
    self.amountMicrousd = amountMicrousd
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownKeys(["status", "amountMicrousd"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(WidgetCostStatus.self, forKey: .status)
    amountMicrousd = try container.decodeIfPresent(String.self, forKey: .amountMicrousd)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .status,
        in: container,
        debugDescription: "Invalid widget cost."
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    guard isValid else {
      throw EncodingError.invalidValue(
        self,
        EncodingError.Context(
          codingPath: encoder.codingPath,
          debugDescription: "Invalid widget cost."
        )
      )
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(status, forKey: .status)
    try container.encodeIfPresent(amountMicrousd, forKey: .amountMicrousd)
  }

  public var isValid: Bool {
    switch status {
    case .complete, .partial:
      guard let amountMicrousd else { return false }
      return WidgetValidation.isNonnegativeInteger(amountMicrousd)
    case .unavailable:
      return amountMicrousd == nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case status
    case amountMicrousd
  }
}

enum WidgetValidation {
  static let jsonSafeIntegerMaximum = 9_007_199_254_740_991

  static func isTrimmedText(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.count <= maximum
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func isSafeNonnegative(_ value: Int) -> Bool {
    (0...jsonSafeIntegerMaximum).contains(value)
  }

  static func isNonnegativeInteger(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 32,
      value.utf8.allSatisfy({ (48...57).contains($0) })
    else { return false }
    return value == "0" || value.first != "0"
  }

  static func isFiniteDate(_ date: Date) -> Bool {
    date.timeIntervalSinceReferenceDate.isFinite
  }
}

struct WidgetCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}

extension Decoder {
  fileprivate func rejectUnknownKeys(_ knownKeys: Set<String>) throws {
    let container = try container(keyedBy: WidgetCodingKey.self)
    guard let unknownKey = container.allKeys.first(where: { !knownKeys.contains($0.stringValue) })
    else {
      return
    }
    throw DecodingError.dataCorrupted(
      DecodingError.Context(
        codingPath: codingPath + [unknownKey],
        debugDescription: "Unknown widget field: \(unknownKey.stringValue)"
      )
    )
  }
}

enum WidgetSnapshotCodec {
  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)

      let fractionalFormatter = ISO8601DateFormatter()
      fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractionalFormatter.date(from: value) {
        return date
      }

      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      if let date = formatter.date(from: value) {
        return date
      }

      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected an ISO 8601 date-time."
      )
    }
    return decoder
  }

  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      try container.encode(formatter.string(from: date))
    }
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  static func decode(_ data: Data) throws -> WidgetSnapshot {
    try makeDecoder().decode(WidgetSnapshot.self, from: data)
  }

  static func encode(_ value: WidgetSnapshot) throws -> Data {
    try makeEncoder().encode(value)
  }
}
