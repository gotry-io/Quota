import QuotaWire

/// Agent → provider → model grouping for one Usage period, with the five-row provider fold.
enum UsageBreakdown {
  static let collapsedModelLimit = 5

  struct AgentSection: Identifiable, Equatable, Sendable {
    let agent: BillingAgent
    let providers: [ProviderSection]

    var id: String { agent.rawValue }
    var displayName: String { AgentDisplay.name(agent) }
  }

  struct ProviderSection: Identifiable, Equatable, Sendable {
    let provider: InferenceProvider
    let models: [ModelRow]

    var id: String { provider.rawValue }
    var displayName: String { provider.displayName }

    func expansionKey(agentID: String) -> String {
      "\(agentID)|\(id)"
    }

    func visibleModels(expanded: Bool) -> [ModelRow] {
      guard !expanded, models.count > UsageBreakdown.collapsedModelLimit else { return models }
      return Array(models.prefix(UsageBreakdown.collapsedModelLimit))
    }

    func hiddenCount(expanded: Bool) -> Int {
      models.count - visibleModels(expanded: expanded).count
    }
  }

  struct ModelRow: Identifiable, Equatable, Sendable {
    let id: String
    let model: String
    let totals: UsageSummaryTotals
    let cost: UsageCostOutcome

    var displayName: String { ModelDisplay.name(model) }
  }

  static func sections(in period: UsagePeriod) -> [AgentSection] {
    period.agents.map { agent in
      AgentSection(
        agent: agent.agent,
        providers: agent.providers.map { provider in
          ProviderSection(
            provider: provider.provider,
            models: provider.models.enumerated().map { index, model in
              ModelRow(
                id: "\(index)|\(model.model)",
                model: model.model,
                totals: model.totals,
                cost: model.cost
              )
            }
          )
        }
      )
    }
  }
}
