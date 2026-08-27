import Foundation

/// A coding key that names whatever the payload named, so unknown keys can be seen at all.
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
  /// Refuse a private IPC payload naming a field this build does not read.
  ///
  /// The local service and this app ship in the same build and speak one `ipc_version`, so a key
  /// neither side stated is a defect in one of them rather than a newer peer. Relay reads are the
  /// other case and are tolerant; see
  /// [ADR 0023](../../../../../../docs/decisions/0023-strict-writes-tolerant-reads.md).
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
