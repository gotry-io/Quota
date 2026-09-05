import QuotaPresentation
import QuotaWidgetData
import SwiftUI
import WidgetKit

/// Live ticking countdown under 24h; otherwise the shared static reset line; nothing once past.
func overviewResetText(resetsAt: Date, now: Date) -> Text? {
  if OverviewWidgetContent.usesLiveResetCountdown(resetsAt: resetsAt, now: now) {
    return Text("Resets ") + Text(timerInterval: now...resetsAt, countsDown: true)
  }
  return FreshnessCopy.resetCopy(resetsAt: resetsAt, now: now).map(Text.init)
}

struct OverviewSmallView: View {
  var entry: OverviewEntry

  var body: some View {
    if entry.isPlaceholder {
      placeholder
    } else if let item = OverviewWidgetContent.primaryItem(
      from: entry.snapshot,
      configuredSelectionID: entry.configuredSelectionID
    ) {
      Link(destination: OverviewWidgetContent.subscriptionURL(for: item)) {
        VStack(alignment: .leading, spacing: 4) {
          Text(OverviewWidgetContent.remainingLabel(for: item))
            .font(.title2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.primary)
            .widgetAccentable()
            .minimumScaleFactor(0.65)
            .lineLimit(1)
          Text(item.providerDisplayName)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text(item.windowTitle)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
          Spacer(minLength: 0)
          supportLine(item: item, fetchedAt: entry.snapshot?.fetchedAt)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          OverviewWidgetContent.itemAccessibility(
            item: item,
            fetchedAt: entry.snapshot?.fetchedAt,
            now: entry.date
          )
        )
      }
      .widgetURL(OverviewWidgetContent.subscriptionURL(for: item))
    } else {
      noData
    }
  }

  private var placeholder: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("--%")
        .font(.title2.monospacedDigit().weight(.semibold))
        .redacted(reason: .placeholder)
      Text("Provider")
        .font(.subheadline)
        .redacted(reason: .placeholder)
      Text("Window")
        .font(.caption)
        .redacted(reason: .placeholder)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .accessibilityLabel("Quota overview placeholder")
  }

  private var noData: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Quota")
        .font(.headline)
      Text("No data yet")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .accessibilityLabel("Quota overview, no data yet")
  }

  private func supportLine(item: WidgetQuotaItem, fetchedAt: Date?) -> Text {
    var result: Text?
    func append(_ text: Text) {
      if let current = result {
        result = current + Text(" · ") + text
      } else {
        result = text
      }
    }
    // A reading that is not current says so even when it still carries a reset time,
    // because the reset it names may already have passed.
    if let state = item.stateLabel(now: entry.date) {
      append(Text(state))
    }
    if let resetsAt = item.resetsAt,
      let reset = overviewResetText(resetsAt: resetsAt, now: entry.date)
    {
      append(reset)
    }
    if let fetchedAt {
      append(Text(OverviewWidgetContent.updated(fetchedAt: fetchedAt, now: entry.date)))
    }
    return result ?? Text(" ")
  }
}

struct OverviewMediumView: View {
  var entry: OverviewEntry

  var body: some View {
    if entry.isPlaceholder {
      HStack(spacing: 12) {
        OverviewSmallView(entry: entry)
        OverviewSmallView(entry: entry)
      }
    } else if let snapshot = entry.snapshot, !snapshot.items.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: 12) {
          ForEach(
            Array(
              OverviewWidgetContent.mediumItems(
                from: snapshot,
                configuredSelectionID: entry.configuredSelectionID
              ).enumerated()),
            id: \.offset
          ) { _, item in
            Link(destination: OverviewWidgetContent.subscriptionURL(for: item)) {
              itemColumn(item: item)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .widgetURL(OverviewWidgetContent.subscriptionURL(for: item))
          }
        }
        footer(snapshot: snapshot)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    } else {
      OverviewSmallView(entry: entry)
    }
  }

  private func itemColumn(item: WidgetQuotaItem) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(OverviewWidgetContent.remainingLabel(for: item))
        .font(.title3.monospacedDigit().weight(.semibold))
        .foregroundStyle(.primary)
        .widgetAccentable()
        .minimumScaleFactor(0.65)
        .lineLimit(1)
      Text(item.providerDisplayName)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Text(item.windowTitle)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
      if let resetsAt = item.resetsAt,
        let reset = overviewResetText(resetsAt: resetsAt, now: entry.date)
      {
        reset
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      OverviewWidgetContent.itemAccessibility(
        item: item,
        fetchedAt: entry.snapshot?.fetchedAt,
        now: entry.date
      )
    )
  }

  private func footer(snapshot: WidgetSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(
          OverviewWidgetContent.todayTokensLabel(
            input: snapshot.today.inputTokens,
            output: snapshot.today.outputTokens
          )
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        Spacer(minLength: 4)
        Text(OverviewWidgetContent.costLabel(for: snapshot.today.cost))
          .font(.caption.monospacedDigit().weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      Text(OverviewWidgetContent.updated(fetchedAt: snapshot.fetchedAt, now: entry.date))
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Today, \(OverviewWidgetContent.todayTokensAccessibility(input: snapshot.today.inputTokens, output: snapshot.today.outputTokens)), \(OverviewWidgetContent.costAccessibility(for: snapshot.today.cost)), \(OverviewWidgetContent.updated(fetchedAt: snapshot.fetchedAt, now: entry.date))"
    )
  }
}

struct OverviewLargeView: View {
  var entry: OverviewEntry

  var body: some View {
    if entry.isPlaceholder {
      placeholder
    } else if let snapshot = entry.snapshot, !snapshot.items.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(
          Array(
            OverviewWidgetContent.largeItems(
              from: snapshot,
              configuredSelectionID: entry.configuredSelectionID
            ).enumerated()),
          id: \.offset
        ) { _, item in
          Link(destination: OverviewWidgetContent.subscriptionURL(for: item)) {
            row(item: item)
          }
        }
        Spacer(minLength: 0)
        Text(OverviewWidgetContent.updated(fetchedAt: snapshot.fetchedAt, now: entry.date))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
          .accessibilityLabel(
            OverviewWidgetContent.updated(fetchedAt: snapshot.fetchedAt, now: entry.date)
          )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    } else {
      OverviewSmallView(entry: entry)
    }
  }

  private func row(item: WidgetQuotaItem) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("\(item.providerDisplayName) · \(item.windowTitle)")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
        Spacer(minLength: 4)
        Text(OverviewWidgetContent.remainingLabel(for: item))
          .font(.headline.monospacedDigit().weight(.semibold))
          .foregroundStyle(.primary)
          .widgetAccentable()
          .lineLimit(1)
          .minimumScaleFactor(0.65)
      }
      if !OverviewWidgetContent.isBalanceOnly(item) {
        ProgressView(value: item.remainingPercent, total: 100)
          .accessibilityHidden(true)
      }
      if let resetsAt = item.resetsAt,
        let reset = overviewResetText(resetsAt: resetsAt, now: entry.date)
      {
        reset
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      OverviewWidgetContent.itemAccessibility(
        item: item,
        fetchedAt: entry.snapshot?.fetchedAt,
        now: entry.date
      )
    )
  }

  private var placeholder: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(0..<3, id: \.self) { _ in
        VStack(alignment: .leading, spacing: 4) {
          Text("Provider · Window")
            .font(.subheadline)
            .redacted(reason: .placeholder)
          Text("--%")
            .font(.headline.monospacedDigit())
            .redacted(reason: .placeholder)
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .accessibilityLabel("Quota overview placeholder")
  }
}

struct OverviewCircularView: View {
  var entry: OverviewEntry

  var body: some View {
    if let item = OverviewWidgetContent.primaryItem(
      from: entry.snapshot,
      configuredSelectionID: entry.configuredSelectionID
    ), !entry.isPlaceholder {
      Link(destination: OverviewWidgetContent.subscriptionURL(for: item)) {
        Group {
          if OverviewWidgetContent.isBalanceOnly(item) {
            balanceContent(item)
          } else {
            percentGauge(item)
          }
        }
        .accessibilityLabel(
          OverviewWidgetContent.itemAccessibility(
            item: item,
            fetchedAt: entry.snapshot?.fetchedAt,
            now: entry.date
          )
        )
      }
      .widgetURL(OverviewWidgetContent.subscriptionURL(for: item))
    } else {
      ZStack {
        AccessoryWidgetBackground()
        Text(entry.isPlaceholder ? "--" : "—")
          .font(.headline.monospacedDigit())
          .widgetAccentable()
      }
      .accessibilityLabel(
        entry.isPlaceholder ? "Quota overview placeholder" : "Quota overview, no data yet"
      )
    }
  }

  private func percentGauge(_ item: WidgetQuotaItem) -> some View {
    Gauge(value: item.remainingPercent, in: 0...100) {
      Text(item.providerDisplayName)
    } currentValueLabel: {
      Text(OverviewWidgetContent.percentLabel(for: item))
        .font(.system(.body, design: .rounded).monospacedDigit().weight(.semibold))
        .minimumScaleFactor(0.45)
        .lineLimit(1)
        .widgetAccentable()
    }
    .gaugeStyle(.accessoryCircular)
  }

  private func balanceContent(_ item: WidgetQuotaItem) -> some View {
    ZStack {
      AccessoryWidgetBackground()
      Text(OverviewWidgetContent.remainingLabel(for: item))
        .font(.system(.body, design: .rounded).monospacedDigit().weight(.semibold))
        .widgetAccentable()
        .minimumScaleFactor(0.45)
        .lineLimit(1)
        .padding(6)
    }
  }
}

struct OverviewRectangularView: View {
  var entry: OverviewEntry

  var body: some View {
    if let item = OverviewWidgetContent.primaryItem(
      from: entry.snapshot,
      configuredSelectionID: entry.configuredSelectionID
    ), !entry.isPlaceholder {
      Link(destination: OverviewWidgetContent.subscriptionURL(for: item)) {
        VStack(alignment: .leading, spacing: 2) {
          Text(OverviewWidgetContent.remainingLabel(for: item))
            .font(.headline.monospacedDigit().weight(.semibold))
            .widgetAccentable()
            .lineLimit(1)
            .minimumScaleFactor(0.65)
          Text("\(item.providerDisplayName) · \(item.windowTitle)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
          if let resetsAt = item.resetsAt,
            let reset = overviewResetText(resetsAt: resetsAt, now: entry.date)
          {
            reset
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .minimumScaleFactor(0.85)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          OverviewWidgetContent.itemAccessibility(
            item: item,
            fetchedAt: entry.snapshot?.fetchedAt,
            now: entry.date
          )
        )
      }
      .widgetURL(OverviewWidgetContent.subscriptionURL(for: item))
    } else {
      VStack(alignment: .leading, spacing: 2) {
        Text("Quota")
          .font(.headline)
        Text(entry.isPlaceholder ? "Loading" : "No data yet")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .accessibilityLabel(
        entry.isPlaceholder ? "Quota overview placeholder" : "Quota overview, no data yet"
      )
    }
  }
}

struct OverviewInlineView: View {
  var entry: OverviewEntry

  var body: some View {
    if let item = OverviewWidgetContent.primaryItem(
      from: entry.snapshot,
      configuredSelectionID: entry.configuredSelectionID
    ), !entry.isPlaceholder {
      Text(OverviewWidgetContent.inlineLabel(for: item))
        .widgetAccentable()
        .accessibilityLabel(
          OverviewWidgetContent.itemAccessibility(
            item: item,
            fetchedAt: entry.snapshot?.fetchedAt,
            now: entry.date
          )
        )
        .widgetURL(OverviewWidgetContent.subscriptionURL(for: item))
    } else {
      Text(entry.isPlaceholder ? "Quota --%" : "Quota —")
        .accessibilityLabel(
          entry.isPlaceholder ? "Quota overview placeholder" : "Quota overview, no data yet"
        )
    }
  }
}

// MARK: - Preview fixtures (synthetic display data only; no credentials)

private enum OverviewWidgetPreviewFixtures {
  static let now = Date(timeIntervalSince1970: 1_786_723_200)  // 2026-08-14T16:00:00Z

  static let contentSnapshot = WidgetSnapshot(
    fetchedAt: now.addingTimeInterval(-900),
    items: [
      WidgetQuotaItem(
        selectionID: "aaaaaaaaaaaa",
        providerID: "codex",
        providerDisplayName: "Codex",
        windowTitle: "5 Hours",
        remainingPercent: 68,
        hasLimit: true,
        resetsAt: now.addingTimeInterval(2_700)
      ),
      WidgetQuotaItem(
        selectionID: "bbbbbbbbbbbb",
        providerID: "claude",
        providerDisplayName: "Claude Code",
        windowTitle: "5 Hours",
        remainingPercent: 53,
        hasLimit: true,
        resetsAt: now.addingTimeInterval(7_200)
      ),
      WidgetQuotaItem(
        selectionID: "cccccccccccc",
        providerID: "openrouter",
        providerDisplayName: "OpenRouter",
        windowTitle: "Balance",
        remainingPercent: 100,
        remainingValue: 12.5,
        unit: .usd,
        hasLimit: false
      ),
      WidgetQuotaItem(
        selectionID: "dddddddddddd",
        providerID: "grok",
        providerDisplayName: "Grok",
        windowTitle: "Weekly",
        remainingPercent: 81,
        hasLimit: true,
        resetsAt: now.addingTimeInterval(200_000)
      ),
      WidgetQuotaItem(
        selectionID: "eeeeeeeeeeee",
        providerID: "gemini",
        providerDisplayName: "Gemini",
        windowTitle: "Daily",
        remainingPercent: 44,
        hasLimit: true,
        resetsAt: now.addingTimeInterval(3_600)
      ),
      WidgetQuotaItem(
        selectionID: "ffffffffffff",
        providerID: "cursor",
        providerDisplayName: "Cursor",
        windowTitle: "Monthly",
        remainingPercent: 22,
        hasLimit: true,
        resetsAt: now.addingTimeInterval(86_400 * 10)
      ),
    ],
    today: WidgetTodayUsage(
      inputTokens: 142_050,
      outputTokens: 28_412,
      cost: WidgetCost(status: .complete, amountMicrousd: "1489234")
    )
  )

  static func entry(
    snapshot: WidgetSnapshot?,
    isPlaceholder: Bool = false,
    configuredSelectionID: String? = nil
  ) -> OverviewEntry {
    OverviewEntry(
      date: now,
      snapshot: snapshot,
      isPlaceholder: isPlaceholder,
      configuredSelectionID: configuredSelectionID
    )
  }
}

#Preview("Small content", as: .systemSmall) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: OverviewWidgetPreviewFixtures.contentSnapshot)
}

#Preview("Small no data", as: .systemSmall) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil)
}

#Preview("Small placeholder", as: .systemSmall) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil, isPlaceholder: true)
}

#Preview("Medium content", as: .systemMedium) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: OverviewWidgetPreviewFixtures.contentSnapshot)
}

#Preview("Medium no data", as: .systemMedium) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil)
}

#Preview("Medium placeholder", as: .systemMedium) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil, isPlaceholder: true)
}

#Preview("Large content", as: .systemLarge) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: OverviewWidgetPreviewFixtures.contentSnapshot)
}

#Preview("Large no data", as: .systemLarge) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil)
}

#Preview("Large placeholder", as: .systemLarge) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil, isPlaceholder: true)
}

#Preview("Circular content", as: .accessoryCircular) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: OverviewWidgetPreviewFixtures.contentSnapshot)
}

#Preview("Circular no data", as: .accessoryCircular) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil)
}

#Preview("Circular placeholder", as: .accessoryCircular) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil, isPlaceholder: true)
}

#Preview("Rectangular content", as: .accessoryRectangular) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: OverviewWidgetPreviewFixtures.contentSnapshot)
}

#Preview("Rectangular no data", as: .accessoryRectangular) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil)
}

#Preview("Rectangular placeholder", as: .accessoryRectangular) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil, isPlaceholder: true)
}

#Preview("Inline content", as: .accessoryInline) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: OverviewWidgetPreviewFixtures.contentSnapshot)
}

#Preview("Inline no data", as: .accessoryInline) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil)
}

#Preview("Inline placeholder", as: .accessoryInline) {
  OverviewWidget()
} timeline: {
  OverviewWidgetPreviewFixtures.entry(snapshot: nil, isPlaceholder: true)
}
