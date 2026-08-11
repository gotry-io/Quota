import Foundation

private struct WireCodingKey: CodingKey {
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
  func rejectUnknownWireKeys(_ knownKeys: Set<String>) throws {
    let container = try container(keyedBy: WireCodingKey.self)
    guard let unknownKey = container.allKeys.first(where: { !knownKeys.contains($0.stringValue) })
    else {
      return
    }
    throw DecodingError.dataCorrupted(
      DecodingError.Context(
        codingPath: codingPath + [unknownKey],
        debugDescription: "Unknown wire field: \(unknownKey.stringValue)"
      )
    )
  }
}
