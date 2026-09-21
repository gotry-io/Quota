import Foundation
import QuotaPresentation

public enum WireCodec {
  public static let oauthProtocolVersion = QuotaProtocol.control
  public static let managedDataProtocolVersion = QuotaProtocol.managedData
  public static let jsonSafeIntegerMaximum = 9_007_199_254_740_991
  public static let maximumResponseBytes = 1_048_576
  /// One period's agent tree carries at most this many model leaves; a reader uses the same
  /// cap for an activity day's optional `agents` array.
  public static let maximumUsagePeriodLeaves = 200
  /// Inclusive local days one Account period read may name. Mirrors the protocol bound.
  public static let maximumUsagePeriodDays = 366
  /// Hour-grid rule every local-date period names. See ADR 0055.
  public static let usageHourGridRule =
    "first_whole_hour_of_local_date; fractional_midnight_to_previous_day; no_proration"

  public static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      if let date = WireDates.date(from: value) {
        return date
      }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected an ISO 8601 date-time."
      )
    }
    return decoder
  }

  public static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(WireDates.string(from: date))
    }
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  public static func makeRequestEncoder() -> JSONEncoder {
    let encoder = makeEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
  }

  public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    if data.count > maximumResponseBytes {
      throw WireLimitError.responseTooLarge
    }
    return try makeDecoder().decode(type, from: data)
  }

  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    try makeEncoder().encode(value)
  }

  public static func encodeRequest<T: Encodable>(_ value: T) throws -> Data {
    try makeRequestEncoder().encode(value)
  }
}

public enum WireLimitError: Error, Sendable, Equatable {
  case responseTooLarge
}

/// Shared ISO-8601 formatters. Creating one per field is the expensive part of decode.
private enum WireDates {
  private static let lock = NSLock()
  nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  nonisolated(unsafe) private static let internet: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  static func date(from value: String) -> Date? {
    lock.lock()
    defer { lock.unlock() }
    return fractional.date(from: value) ?? internet.date(from: value)
  }

  static func string(from date: Date) -> String {
    lock.lock()
    defer { lock.unlock() }
    return internet.string(from: date)
  }
}

public enum QuotaIOSOAuth {
  public static let clientID = "quota-ios"
  public static let redirectURI = "io.gotry.quota:/oauth/callback"
  public static let callbackScheme = "io.gotry.quota"
  public static let accessTokenPrefix = "qia_"
  public static let refreshTokenPrefix = "qiar_"
}
