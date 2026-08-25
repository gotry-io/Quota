import Foundation
import QuotaPresentation

/// User-facing provider status. Protocol outcomes stay richer; UI collapses to these.
enum ProviderStatusKind: Equatable {
  /// Session missing/expired. Recovery is a login command.
  case needsSignIn
  /// Temporary outage, unsupported surface, or generic read failure.
  case unavailable
  /// Collector could not classify further; still not a login problem.
  case cantRefresh
}

struct ProviderStatusCopy: Equatable {
  let kind: ProviderStatusKind
  /// Quiet trailing label. Authentication recovery uses detail only.
  let title: String?
  /// Optional recovery/detail line under the provider header.
  let detail: String?
  let accessibilityLabel: String

  static func from(result: QuotaCollectionResult) -> ProviderStatusCopy? {
    let kind: ProviderStatusKind
    let state: QuotaObservationState
    var detailFallback: String?
    switch result.outcome {
    case .success:
      return nil
    case .authRequired:
      // A rejected sign-in explains itself; an absent one is setup that never happened.
      // Recovery is the whole message, so the title only names the source that was
      // rejected: an expired OAuth grant and a stale saved browser session are fixed in
      // different places, and a provider that was never set up here names nothing.
      let detail = conciseMessage(result.message) ?? "Account setup required."
      let source = result.failingSource?.displayName
      return ProviderStatusCopy(
        kind: .needsSignIn,
        title: source,
        detail: detail,
        accessibilityLabel: source.map { accessibility(title: $0, detail: detail) } ?? detail
      )
    case .unavailable:
      kind = .unavailable
      state = .unavailable
    case .unsupported:
      kind = .unavailable
      state = .unavailable
      detailFallback = "Not supported here."
    case .error:
      kind = .cantRefresh
      state = .failed
    }
    // One spelling for one word: the same failure can appear as this row's status and as an
    // account device's observation state in the same block.  The source that failed goes in
    // front of it, because "unavailable" says nothing about which reading to go fix.
    let detail = conciseMessage(result.message) ?? detailFallback
    let title = result.failingSource.map { "\($0.displayName) · \(state.label)" } ?? state.label
    return ProviderStatusCopy(
      kind: kind,
      title: title,
      detail: detail,
      accessibilityLabel: accessibility(title: title, detail: detail)
    )
  }

  static func conciseMessage(_ message: String?) -> String? {
    guard let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else {
      return nil
    }
    if extractLoginCommand(from: trimmed) != nil {
      return nil
    }
    if trimmed.count <= 96 {
      return trimmed
    }
    if let period = trimmed.firstIndex(of: ".") {
      let sentence = String(trimmed[...period]).trimmingCharacters(in: .whitespacesAndNewlines)
      if sentence.count >= 12, sentence.count <= 96 {
        return sentence
      }
    }
    return String(trimmed.prefix(93)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }

  private static func extractLoginCommand(from message: String?) -> String? {
    guard let message else { return nil }
    guard let match = message.range(of: #"`([^`]+)`"#, options: .regularExpression) else {
      return nil
    }
    let full = String(message[match])
    let command = String(full.dropFirst().dropLast())
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return command.isEmpty ? nil : command
  }

  private static func accessibility(title: String, detail: String?) -> String {
    if let detail, !detail.isEmpty {
      return "\(title). \(detail)"
    }
    return title
  }
}
