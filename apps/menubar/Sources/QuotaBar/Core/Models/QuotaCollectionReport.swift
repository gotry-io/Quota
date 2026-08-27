import Foundation
import QuotaPresentation
import QuotaWire

enum CollectionOutcome: String, Codable, Sendable {
  case success
  case authRequired = "auth_required"
  case unavailable
  case unsupported
  case error
}

/// The precise verdict a source reached, including the one `CollectionOutcome` folds away.
enum CollectionSourceCategory: String, Codable, Sendable {
  case success
  case authRequired = "auth_required"
  case accessDenied = "access_denied"
  case unavailable
  case unsupported
  case error
}

/// One credential source discovered on this Mac, and what reading it produced.
///
/// `outcome` is the wire spelling, which folds a refusal into `unavailable` because no other
/// device can see or change this Mac's access. `category` keeps the two apart for the reader
/// who can act on the difference.
struct QuotaCollectionSource: Codable, Equatable, Sendable {
  let sourceID: String
  let outcome: CollectionOutcome
  let category: CollectionSourceCategory

  private enum CodingKeys: String, CodingKey {
    case sourceID = "sourceId"
    case outcome
    case category
  }
}

extension QuotaCollectionSource {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["sourceId", "outcome", "category"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sourceID = try container.decode(String.self, forKey: .sourceID)
    outcome = try container.decode(CollectionOutcome.self, forKey: .outcome)
    category = try container.decode(CollectionSourceCategory.self, forKey: .category)
    guard !sourceID.isEmpty, sourceID.count <= 64,
      (outcome == .success) == (category == .success)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .sourceID,
        in: container,
        debugDescription: "Invalid quota collection source."
      )
    }
  }

  /// What a person calls this source.
  var displayName: String { Self.displayName(forSourceID: sourceID) }

  /// The same, for a source id arriving on its own — a diagnostic report names the rung that
  /// answered with these ids too.
  ///
  /// The report crosses IPC as ids and nothing else, so this table is the only place they are
  /// named. A source this build does not know still names something real, so it reads as a
  /// provider rather than as nothing.
  static func displayName(forSourceID sourceID: String) -> String {
    switch sourceID {
    case "anthropic_oauth_usage_api", "anthropic_oauth_signed_out", "chatgpt_usage_api",
      "grok_billing_api", "grok_billing_rpc":
      "OAuth"
    case "codex_pat_usage_api": "Access token"
    case "browser_session", "chatgpt_web_usage_api", "claude_web_usage_api",
      "grok_web_billing_api", "kimi_web_billing_api", "cursor_dashboard_api":
      "Browser session"
    case "cursor_app_auth": "Cursor app session"
    case "kimi_code_cli_credential": "Kimi Code token"
    case "kimi_code_usages_api", "openrouter_api", "deepseek_balance_api", "litellm_budget_api":
      "API key"
    default: "Provider"
    }
  }
}

struct QuotaCollectionResult: Codable, Equatable, Sendable {
  let provider: ProviderID
  let outcome: CollectionOutcome
  let snapshots: [QuotaSnapshot]
  let source: String?
  let message: String?
  /// The credential sources discovered for this provider, each naming the rung that
  /// answered for it. Empty means the provider was never set up on this Mac, which is not
  /// the same failure as one that was.
  let sources: [QuotaCollectionSource]
  /// Set when this Mac was refused a credential it holds. It reads as `unavailable` to every
  /// other device, because none of them can see or change this one's access.
  let accessDenied: Bool?
}

extension QuotaCollectionResult {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "provider", "outcome", "snapshots", "source", "message", "sources", "accessDenied",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(ProviderID.self, forKey: .provider)
    outcome = try container.decode(CollectionOutcome.self, forKey: .outcome)
    snapshots = try container.decode([QuotaSnapshot].self, forKey: .snapshots)
    source = try container.decodeIfPresent(String.self, forKey: .source)
    message = try container.decodeIfPresent(String.self, forKey: .message)
    sources = try container.decode([QuotaCollectionSource].self, forKey: .sources)
    accessDenied = try decodeTrueMarker(.accessDenied, from: container)
    let isSuccess = outcome == .success
    guard isSuccess == !snapshots.isEmpty,
      snapshots.count <= 32,
      sources.count <= 32,
      // A reading came from somewhere: a success that names no source is a report that
      // cannot say where its numbers are from.
      !isSuccess || sources.contains(where: { $0.outcome == .success }),
      snapshots.allSatisfy({ $0.provider == provider })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .snapshots,
        in: container,
        debugDescription: "Invalid quota collection result."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case outcome
    case snapshots
    case source
    case message
    case sources
    case accessDenied
  }

  /// The source whose failure decided this result: the last one that did not answer.
  var failingSource: QuotaCollectionSource? {
    sources.last { $0.outcome != .success }
  }
}

struct QuotaCollectionReport: Codable, Equatable, Sendable {
  let capturedAt: Date
  let results: [QuotaCollectionResult]

  private enum CodingKeys: String, CodingKey {
    case capturedAt
    case results
  }
}

extension QuotaCollectionReport {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["capturedAt", "results"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    results = try container.decode([QuotaCollectionResult].self, forKey: .results)
    guard results.count <= ProviderID.allCases.count else {
      throw DecodingError.dataCorruptedError(
        forKey: .results,
        in: container,
        debugDescription: "A quota report cannot name more providers than exist."
      )
    }
  }
}
