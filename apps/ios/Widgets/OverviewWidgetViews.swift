import QuotaPresentation
import QuotaWidgetData
import SwiftUI
import WidgetKit

struct OverviewSmallView: View {
  var entry: OverviewEntry

  var body: some View {
    if entry.isPlaceholder {
      placeholder
    } else if let item = OverviewWidgetContent.primaryItem(from: entry.snapshot) {
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
    var parts: [String] = []
    if let resetsAt = item.resetsAt {
      parts.append("Resets \(OverviewWidgetContent.resetAge(resetsAt: resetsAt, now: entry.date))")
    } else if item.isStale == true {
      parts.append("Stale")
    }
    if let fetchedAt {
      parts.append("Updated \(OverviewWidgetContent.updatedAge(fetchedAt: fetchedAt, now: entry.date))")
    }
    return Text(parts.isEmpty ? " " : parts.joined(separator: " · "))
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
          ForEach(Array(OverviewWidgetContent.mediumItems(from: snapshot).enumerated()), id: \.offset)
          { _, item in
            itemColumn(item: item)
              .frame(maxWidth: .infinity, alignment: .leading)
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
      if let resetsAt = item.resetsAt {
        Text("Resets \(OverviewWidgetContent.resetAge(resetsAt: resetsAt, now: entry.date))")
          .font(.caption2)
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
      Text(
        "Updated \(OverviewWidgetContent.updatedAge(fetchedAt: snapshot.fetchedAt, now: entry.date))"
      )
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.tertiary)
      .lineLimit(1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Today, \(OverviewWidgetContent.todayTokensAccessibility(input: snapshot.today.inputTokens, output: snapshot.today.outputTokens)), \(OverviewWidgetContent.costAccessibility(for: snapshot.today.cost)), Updated \(OverviewWidgetContent.updatedAge(fetchedAt: snapshot.fetchedAt, now: entry.date))"
    )
  }
}

struct OverviewCircularView: View {
  var entry: OverviewEntry

  var body: some View {
    if let item = OverviewWidgetContent.primaryItem(from: entry.snapshot), !entry.isPlaceholder {
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
    if let item = OverviewWidgetContent.primaryItem(from: entry.snapshot), !entry.isPlaceholder {
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
        if let resetsAt = item.resetsAt {
          Text("Resets \(OverviewWidgetContent.resetAge(resetsAt: resetsAt, now: entry.date))")
            .font(.caption2)
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

// MARK: - Preview fixtures (synthetic display data only; no credentials)

private enum OverviewWidgetPreviewFixtures {
  static let now = Date(timeIntervalSince1970: 1_786_723_200)  // 2026-08-14T16:00:00Z

  static let contentSnapshot = WidgetSnapshot(
    fetchedAt: now.addingTimeInterval(-900),
    items: [
      WidgetQuotaItem(
        providerID: "codex",
        providerDisplayName: "Codex",
        windowTitle: "5 hour",
        remainingPercent: 68,
        hasLimit: true,
        resetsAt: now.addingTimeInterval(2_700)
      ),
      WidgetQuotaItem(
        providerID: "claude",
        providerDisplayName: "Claude Code",
        windowTitle: "Session",
        remainingPercent: 53,
        hasLimit: true,
        resetsAt: now.addingTimeInterval(7_200)
      ),
      WidgetQuotaItem(
        providerID: "openrouter",
        providerDisplayName: "OpenRouter",
        windowTitle: "Balance",
        remainingPercent: 100,
        remainingValue: 12.5,
        unit: .usd,
        hasLimit: false
      ),
    ],
    today: WidgetTodayUsage(
      inputTokens: 142_050,
      outputTokens: 28_412,
      cost: WidgetCost(status: .complete, amountMicrousd: "1489234")
    )
  )

  static func entry(snapshot: WidgetSnapshot?, isPlaceholder: Bool = false) -> OverviewEntry {
    OverviewEntry(date: now, snapshot: snapshot, isPlaceholder: isPlaceholder)
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
