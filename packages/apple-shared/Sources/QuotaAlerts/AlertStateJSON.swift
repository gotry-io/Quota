import Foundation

/// Owner-only JSON for `AlertDedupState`. Each app chooses the file; this type only encodes.
public enum AlertStateJSON {
  public static func encode(_ state: AlertDedupState) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(AlertDedupStateDTO(state))
  }

  public static func decode(_ data: Data) throws -> AlertDedupState {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(AlertDedupStateDTO.self, from: data).model
  }
}

private struct AlertDedupStateDTO: Codable {
  var fired: [AlertDedupKeyDTO]
  var readings: [AlertStoredReadingDTO]

  init(_ state: AlertDedupState) {
    let sorted = state.sorted()
    fired = sorted.fired.map(AlertDedupKeyDTO.init)
    readings = sorted.readings.map(AlertStoredReadingDTO.init)
  }

  var model: AlertDedupState {
    AlertDedupState(
      fired: fired.map(\.model),
      readings: readings.map(\.model)
    ).sorted()
  }
}

private struct AlertDedupKeyDTO: Codable {
  var selector: String
  var windowID: String
  var resetsAt: Date?
  var threshold: Int?

  init(_ key: AlertDedupKey) {
    selector = key.selector
    windowID = key.windowID
    resetsAt = key.resetsAt
    threshold = key.threshold
  }

  var model: AlertDedupKey {
    AlertDedupKey(
      selector: selector,
      windowID: windowID,
      resetsAt: resetsAt,
      threshold: threshold
    )
  }

  enum CodingKeys: String, CodingKey {
    case selector
    case windowID = "window_id"
    case resetsAt = "resets_at"
    case threshold
  }
}

private struct AlertStoredReadingDTO: Codable {
  var selector: String
  var windowID: String
  var remainingPercent: Double
  var resetsAt: Date?

  init(_ reading: AlertStoredReading) {
    selector = reading.selector
    windowID = reading.windowID
    remainingPercent = reading.remainingPercent
    resetsAt = reading.resetsAt
  }

  var model: AlertStoredReading {
    AlertStoredReading(
      selector: selector,
      windowID: windowID,
      remainingPercent: remainingPercent,
      resetsAt: resetsAt
    )
  }

  enum CodingKeys: String, CodingKey {
    case selector
    case windowID = "window_id"
    case remainingPercent = "remaining_percent"
    case resetsAt = "resets_at"
  }
}
