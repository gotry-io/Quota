import CryptoKit
import Foundation
import QuotaWire

/// Who a reading belongs to, and what a reader is allowed to see of that.
///
/// Every rule here is the Rust service's, character for character: the fingerprint is the key an
/// account's readings merge on, so a Mac and a phone reading the same account must produce the
/// same string or the account resolves as two.
enum ProviderWebIdentity {
  static func accountIdentity(
    provider: String,
    namespace: String,
    owner: String?
  ) -> (fingerprint: String, scope: FingerprintScope) {
    let trimmed = owner?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let value = trimmed, !value.isEmpty {
      return (sha256Hex("\(provider):global:\(namespace):\(value)"), .global)
    }
    return (sha256Hex("\(provider):source"), .source)
  }

  static func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  /// An address a reader recognizes without the account it names being readable from a screen.
  static func maskEmail(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      let separator = value.firstIndex(of: "@")
    else { return nil }
    let local = String(value[value.startIndex..<separator])
    let domain = String(value[value.index(after: separator)...])
    guard !local.isEmpty, !domain.isEmpty else { return nil }
    return "\(local.prefix(2))***@\(domain)"
  }

  /// The value of one cookie in a stored `Cookie:` header.
  static func cookieNamedValue(_ header: String, _ name: String) -> String? {
    for pair in header.split(separator: ";") {
      let pair = pair.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
      guard let separator = pair.firstIndex(of: "=") else { continue }
      let cookieName = String(pair[pair.startIndex..<separator])
      let value = String(pair[pair.index(after: separator)...])
      if cookieName == name, !value.isEmpty { return value }
    }
    return nil
  }

  /// Who a locally held JWT says it belongs to. The signature is not checked: the bearer already
  /// proves possession, and a forged subject would only give this device a second fingerprint
  /// for an account it cannot read.
  static func jwtSubject(_ token: String) -> String? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count > 1 else { return nil }
    var normalized = parts[1].replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while normalized.count % 4 != 0 { normalized.append("=") }
    guard let data = Data(base64Encoded: normalized), let payload = JSONValue(data: data)
    else { return nil }
    guard
      let subject = ["sub", "user_id", "userId", "uid"]
        .lazy
        .compactMap({ ProviderJSON.string(payload.get($0)) })
        .first
    else { return nil }
    guard !subject.isEmpty, subject.count <= 256, !subject.contains(where: \.isControl)
    else { return nil }
    return subject
  }
}

extension Character {
  /// The service refuses control characters anywhere in a value it will put in a request.
  var isControl: Bool {
    unicodeScalars.count == 1 && CharacterSet.controlCharacters.contains(unicodeScalars.first!)
  }
}
