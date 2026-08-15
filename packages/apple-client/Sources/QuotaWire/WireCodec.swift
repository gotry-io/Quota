import Foundation

public enum WireCodec {
  public static let oauthProtocolVersion = 2
  public static let managedDataProtocolVersion = 3
  public static let jsonSafeIntegerMaximum = 9_007_199_254_740_991
  public static let maximumResponseBytes = 1_048_576

  public static func makeDecoder() -> JSONDecoder {
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

  public static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      try container.encode(formatter.string(from: date))
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

public enum QuotaIOSOAuth {
  public static let clientID = "quota-ios"
  public static let redirectURI = "io.gotry.quota:/oauth/callback"
  public static let callbackScheme = "io.gotry.quota"
  public static let callbackPath = "/oauth/callback"
  public static let accessTokenPrefix = "qia_"
  public static let refreshTokenPrefix = "qiar_"
}
