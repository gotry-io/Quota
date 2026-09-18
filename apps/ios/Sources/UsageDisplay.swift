import QuotaWire

enum ModelDisplay {
  /// The leaf Relay folds overflow into is the model `other`.
  static func name(_ model: String) -> String {
    model == "other" ? "Other" : model
  }
}

extension BillingAgent {
  /// Agents are not providers; these are SF Symbols, not catalog marks.
  var systemImage: String {
    switch self {
    case .codex: "terminal"
    case .claudeCode: "sparkles"
    case .grok: "bolt"
    case .cursor: "cursorarrow"
    case .gemini: "star.circle"
    case .copilot: "airplane"
    case .opencode, .pi, .kilo, .antigravity, .unknown:
      "chevron.left.forwardslash.chevron.right"
    }
  }
}
