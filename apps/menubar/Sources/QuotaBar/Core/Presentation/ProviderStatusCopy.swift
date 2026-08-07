import Foundation

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
  /// Quiet trailing label, e.g. `Needs Sign-In`.
  let title: String
  /// Optional recovery/detail line under the provider header.
  let detail: String?
  let accessibilityLabel: String

  static func from(result: QuotaCollectionResult) -> ProviderStatusCopy? {
    switch result.outcome {
    case .success:
      return nil
    case .authRequired:
      let command = loginCommand(for: result.provider, message: result.message)
      return ProviderStatusCopy(
        kind: .needsSignIn,
        title: "Needs Sign-In",
        detail: "Run `\(command)`",
        accessibilityLabel: "Needs Sign-In. Run \(command)."
      )
    case .unavailable:
      return ProviderStatusCopy(
        kind: .unavailable,
        title: "Unavailable",
        detail: conciseMessage(result.message),
        accessibilityLabel: accessibility(
          title: "Unavailable",
          detail: conciseMessage(result.message)
        )
      )
    case .unsupported:
      return ProviderStatusCopy(
        kind: .unavailable,
        title: "Unavailable",
        detail: conciseMessage(result.message) ?? "Not supported here.",
        accessibilityLabel: accessibility(
          title: "Unavailable",
          detail: conciseMessage(result.message) ?? "Not supported here."
        )
      )
    case .error:
      return ProviderStatusCopy(
        kind: .cantRefresh,
        title: "Can’t Refresh",
        detail: conciseMessage(result.message),
        accessibilityLabel: accessibility(
          title: "Can’t Refresh",
          detail: conciseMessage(result.message)
        )
      )
    }
  }

  static func loginCommand(for provider: ProviderID, message: String? = nil) -> String {
    if let command = extractLoginCommand(from: message) {
      return normalizeLoginCommand(command, provider: provider)
    }
    return provider.loginCommand
  }

  static func hint(for provider: ProviderID, message: String? = nil) -> String {
    "Run `\(loginCommand(for: provider, message: message))`"
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

  private static func normalizeLoginCommand(_ command: String, provider: ProviderID) -> String {
    // Multi-word snippets from error messages are usable as-is; bare tokens fall back to catalog.
    if command.split(whereSeparator: \.isWhitespace).count >= 2 {
      return command
    }
    return provider.loginCommand
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
