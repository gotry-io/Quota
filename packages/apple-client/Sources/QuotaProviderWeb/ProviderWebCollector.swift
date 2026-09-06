import Foundation
import QuotaWire

/// Why a browser-session reading failed. The category is the whole answer, the way it is in the
/// Rust service: provider text never enters it, so a provider response cannot carry a secret into
/// an error, a log line, or the UI.
public enum ProviderWebErrorCategory: String, Equatable, Sendable {
  case authRequired = "auth_required"
  case unavailable
  case unsupported
  case error
}

/// A failed browser-session reading. `source` is the rung that failed, spelled exactly as the
/// Rust collector's `SOURCE` constant, so one account's failures read the same on either device.
public struct ProviderWebError: Error, Equatable, Sendable {
  public let category: ProviderWebErrorCategory
  public let source: String

  public init(_ category: ProviderWebErrorCategory, _ source: String) {
    self.category = category
    self.source = source
  }
}

/// A cookie header the provider has confirmed belongs to a signed-in account.
///
/// The fingerprint is the same one the Mac's service computes for that account, so a reading made
/// on a phone and a reading made on a Mac resolve to one subscription rather than two.
public struct ValidatedBrowserSession: Equatable, Sendable {
  public let accountFingerprint: String
  public let accountLabel: String?

  public init(accountFingerprint: String, accountLabel: String?) {
    self.accountFingerprint = accountFingerprint
    self.accountLabel = accountLabel
  }
}

/// One provider's web session, proven and then read.
///
/// `packages/protocol/fixtures/provider-web-conformance.json` is the shared statement of what each
/// implementation must answer; the Rust collectors answer the same file.
public protocol ProviderWebCollector: Sendable {
  static var provider: ProviderID { get }

  /// Proves the cookie belongs to a signed-in account. Nothing is stored until it answers.
  func validate(cookieHeader: String) async throws -> ValidatedBrowserSession

  /// One reading of the account the cookie signs in as.
  func collect(cookieHeader: String) async throws -> QuotaSnapshot
}
