import QuotaPresentation
import QuotaWire
import SwiftUI

/// Provider and model shares, plus the secondary token counts the Usage root no longer shows.
struct UsageBreakdownDestination: View {
  @Bindable var model: AppModel
  @State private var expandedProviderIDs: Set<String> = []

  var body: some View {
    List {
      if let period = model.usage.usagePeriodValue {
        secondaryCounts(period)
        if model.usage.usagePeriodIsFolded {
          foldedPeriod
        } else {
          let sections = UsageBreakdown.sections(in: period)
          UsageTopModelsSection(sections: sections, periodTokens: period.totals.totalTokens)
          UsageAgentListSections(
            sections: sections,
            periodTokens: period.totals.totalTokens,
            expandedProviderIDs: $expandedProviderIDs
          )
        }
      } else {
        Section {
          Text("No usage was reported for this period.")
            .font(.body)
            .foregroundStyle(Color.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("By provider / By model")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("usage.breakdown")
  }

  private func secondaryCounts(_ period: UsagePeriod) -> some View {
    let totals = period.totals
    let cacheHit =
      UsageMetrics.cacheHitPercentLabel(
        basisPoints: UsageMetrics.cacheHitBasisPoints(
          cacheReadInputTokens: totals.cacheReadInputTokens,
          inputTokens: totals.inputTokens
        )
      ) ?? "—"
    return Section {
      countRow(
        "Input",
        QuotaFormat.compactCount(totals.inputTokens),
        accessibility: "\(QuotaFormat.accessibleCount(totals.inputTokens)) input tokens",
        identifier: "usage.breakdown.input"
      )
      countRow(
        "Output",
        QuotaFormat.compactCount(totals.outputTokens),
        accessibility: "\(QuotaFormat.accessibleCount(totals.outputTokens)) output tokens",
        identifier: "usage.breakdown.output"
      )
      countRow(
        "Cache hit",
        cacheHit,
        caption: QuotaFormat.cacheSaved(period.cacheSaved),
        accessibility: "Cache hit \(cacheHit)",
        identifier: "usage.headline.cache-hit"
      )
      countRow(
        "Reasoning",
        QuotaFormat.compactCount(totals.reasoningTokens),
        accessibility:
          "\(QuotaFormat.accessibleCount(totals.reasoningTokens)) tokens of output",
        identifier: "usage.headline.reasoning"
      )
      countRow(
        "Messages",
        QuotaFormat.compactCount(totals.messages),
        accessibility: "\(QuotaFormat.accessibleCount(totals.messages)) messages",
        identifier: "usage.breakdown.messages"
      )
    } header: {
      Text("Token counts")
        .accessibilityIdentifier("section.header.breakdown-counts")
    }
  }

  private func countRow(
    _ label: String,
    _ value: String,
    caption: String? = nil,
    accessibility: String,
    identifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(label)
          .font(.body)
          .foregroundStyle(Color.primary)
        Spacer(minLength: 8)
        Text(value)
          .font(.body.monospacedDigit())
          .foregroundStyle(Color.primary)
      }
      if let caption {
        Text(caption)
          .font(QuotaDesign.Typography.meta)
          .foregroundStyle(.primary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibility)
    .accessibilityIdentifier(identifier)
  }

  private var foldedPeriod: some View {
    Section {
      Text(
        "This range was added up on this iPhone, so it carries totals only. The model breakdown is on Today, Last 7 days, Last 30 days, and All."
      )
      .font(.body)
      .foregroundStyle(Color.primary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityIdentifier("usage.folded")
  }
}
