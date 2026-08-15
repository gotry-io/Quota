import Foundation

struct WireCodingKey: CodingKey {
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

func decodeTrueMarker<Key: CodingKey>(
  _ key: Key,
  from container: KeyedDecodingContainer<Key>
) throws -> Bool? {
  guard container.contains(key) else { return nil }
  guard try container.decode(Bool.self, forKey: key) else {
    throw DecodingError.dataCorruptedError(
      forKey: key,
      in: container,
      debugDescription: "Truncation markers must be true."
    )
  }
  return true
}
