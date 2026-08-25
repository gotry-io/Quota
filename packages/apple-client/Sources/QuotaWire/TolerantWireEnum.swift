import Foundation

/// A closed wire enum a reader can meet a newer member of.
///
/// The Relay answering can be newer than the build asking, so a member outside this build's set
/// reads as `unknown` instead of discarding the payload that carried it. What this device sends is
/// the other case: it names a member both ends already agree on, and the schemas that guard a write
/// still say so. See
/// [ADR 0023](../../../../docs/decisions/0023-strict-writes-tolerant-reads.md).
public protocol TolerantWireEnum: RawRepresentable, Codable, Sendable where RawValue == String {
  static var unknown: Self { get }
}

extension TolerantWireEnum {
  public init(from decoder: Decoder) throws {
    let rawValue = try decoder.singleValueContainer().decode(String.self)
    self = Self(rawValue: rawValue) ?? .unknown
  }
}
