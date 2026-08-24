import Foundation
import QuotaWire

/// The private IPC codec. Decoding is the same contract QuotaWire speaks, so it is the same
/// decoder; the request encoder is QuotaBar's own, because the local service reads plain
/// ISO 8601 instants rather than the Relay's fractional-second form.
enum QuotaWireCodec {
  static func makeDecoder() -> JSONDecoder { WireCodec.makeDecoder() }

  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}
