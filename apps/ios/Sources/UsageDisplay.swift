import QuotaWire

enum AgentDisplay {
  static func name(_ agent: BillingAgent) -> String {
    switch agent {
    case .codex: "Codex"
    case .claudeCode: "Claude Code"
    case .grok: "Grok"
    case .opencode: "OpenCode"
    case .pi: "Pi"
    case .cursor: "Cursor"
    case .unknown: "Unknown"
    }
  }
}

enum ModelDisplay {
  /// The leaf Relay folds overflow into is the model `other`.
  static func name(_ model: String) -> String {
    model == "other" ? "Other" : model
  }
}
