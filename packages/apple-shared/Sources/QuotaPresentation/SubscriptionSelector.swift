import CryptoKit
import Foundation

/// The stable, irreversible id every Quota client uses to name a subscription in a URL, a
/// preference, or a notification rule.
///
/// The preimage is `provider|fingerprint|fingerprint_scope|source_id`, with an empty source id
/// when the subscription is global. The selector is the first 12 lowercase hex characters of
/// SHA-256 of that UTF-8 string. Fingerprints stay out of paths and logs.
public enum SubscriptionSelector: Sendable {
  public static func make(
    provider: String,
    fingerprint: String,
    fingerprintScope: String,
    sourceID: String?
  ) -> String {
    let preimage = "\(provider)|\(fingerprint)|\(fingerprintScope)|\(sourceID ?? "")"
    let digest = SHA256.hash(data: Data(preimage.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(12))
  }
}

/// The selector as one installation names it. The salt is per installation and never leaves the
/// device that made it, so the same subscription reads as a different id on another device and
/// nothing published beside it can be matched back to the fingerprint it came from.
public enum SelectionIDs: Sendable {
  /// `SHA-256(selector ‖ "|" ‖ salt)` truncated to twelve lowercase hex characters.
  public static func make(selector: String, salt: Data) -> String {
    var preimage = Data(selector.utf8)
    preimage.append(contentsOf: Data("|".utf8))
    preimage.append(salt)
    let digest = SHA256.hash(data: preimage)
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(12))
  }
}
