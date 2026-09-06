import QuotaPresentation
import QuotaWidgetData
import SwiftUI
import WidgetKit

struct OverviewEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot?
  let isPlaceholder: Bool
  let configuredSelectionID: String?

  var selectedItems: [WidgetQuotaItem] {
    OverviewWidgetContent.select(
      items: snapshot?.items ?? [],
      configuredSelectionID: configuredSelectionID
    )
  }
}

/// Live ticking countdown under 24h; otherwise the shared static reset line; nothing once past.
func overviewResetText(resetsAt: Date, now: Date) -> Text? {
  if OverviewWidgetContent.usesLiveResetCountdown(resetsAt: resetsAt, now: now) {
    return Text("Resets ") + Text(timerInterval: now...resetsAt, countsDown: true)
  }
  return FreshnessCopy.resetCopy(resetsAt: resetsAt, now: now).map(Text.init)
}

func overviewEmphasisColor(for item: WidgetQuotaItem) -> Color {
  OverviewWidgetContent.paceRunsOut(item) ? Color.orange : Color.primary
}

struct OverviewSmallView: View {
  var entry: OverviewEntry

  var body: some View {
    let items = OverviewWidgetContent.smallItems(
      from: entry.snapshot,
      configuredSelectionID: entry.configuredSelectionID
    )
    if entry.isPlaceholder {
      placeholder
    } else if !items.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text(items[0].providerDisplayName)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          windowBlock(item)
        }
        Spacer(minLength: 0)
        if let fetchedAt = entry.snapshot?.fetchedAt {
          Text(OverviewWidgetContent.updated(fetchedAt: fetchedAt, now: entry.date))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(smallAccessibility(items: items))
    } else {
      noData
    }
  }

  private func windowBlock(_ item: WidgetQuotaItem) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(OverviewWidgetContent.remainingLabel(for: item))
        .font(.title3.monospacedDigit().weight(.semibold))
        .foregroundStyle(overviewEmphasisColor(for: item))
        .widgetAccentable()
        .minimumScaleFactor(0.65)
        .lineLimit(1)
      HStack(spacing: 4) {
        Text(item.windowTitle)
        if let resetsAt = item.resetsAt,
          let reset = overviewResetText(resetsAt: resetsAt, now: entry.date)
        {
          Text("·")
          reset
        }
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .lineLimit(1)
      .minimumScaleFactor(0.85)
    }
  }

  private func smallAccessibility(items: [WidgetQuotaItem]) -> String {
    let windows = items.map {
      OverviewWidgetContent.itemAccessibility(
        item: $0,
        fetchedAt: nil,
        now: entry.date
      )
    }.joined(separator: ", ")
    guard let fetchedAt = entry.snapshot?.fetchedAt else { return windows }
    return
      "\(windows), \(OverviewWidgetContent.updated(fetchedAt: fetchedAt, now: entry.date))"
  }

  private var placeholder: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Provider")
        .font(.subheadline)
        .redacted(reason: .placeholder)
      Text("--%")
        .font(.title3.monospacedDigit().weight(.semibold))
        .redacted(reason: .placeholder)
      Text("Window")
        .font(.caption)
        .redacted(reason: .placeholder)
      Text("--%")
        .font(.title3.monospacedDigit().weight(.semibold))
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
}

struct OverviewMediumView: View {
  var entry: OverviewEntry

  var body: some View {
    let items = OverviewWidgetContent.mediumItems(
      from: entry.snapshot,
      configuredSelectionID: entry.configuredSelectionID
    )
    if entry.isPlaceholder {
      placeholder
    } else if let snapshot = entry.snapshot, !items.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          Link(destination: OverviewWidgetContent.subscriptionURL(for: item)) {
            providerRow(item: item)
          }
          // A Link tints its label with the accent color, which the hierarchical text
          // styles then resolve against. Rows read as text, not as links.
          .tint(Color.primary)
        }
        Spacer(minLength: 0)
        footer(snapshot: snapshot)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    } else {
      OverviewSmallView(entry: entry)
    }
  }

  private func providerRow(item: WidgetQuotaItem) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(item.providerDisplayName)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(item.windowTitle)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
        Spacer(minLength: 4)
        Text(OverviewWidgetContent.remainingLabel(for: item))
          .font(.subheadline.monospacedDigit().weight(.semibold))
          .foregroundStyle(overviewEmphasisColor(for: item))
          .widgetAccentable()
          .lineLimit(1)
          .minimumScaleFactor(0.65)
      }
      if OverviewWidgetContent.showsPercentMeter(item) {
        Gauge(value: item.remainingPercent, in: 0...100) { EmptyView() }
          .gaugeStyle(.linearCapacity)
          // The rows carry no tint of their own, so the meter names its own fill.
          .tint(Color.secondary)
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
        fetchedAt: nil,
        now: entry.date
      )
    )
  }

  private func footer(snapshot: WidgetSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Text(
          OverviewWidgetContent.todayTokensLabel(
            input: snapshot.today.inputTokens,
            output: snapshot.today.outputTokens
          )
        )
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        Spacer(minLength: 4)
        Text(OverviewWidgetContent.costLabel(for: snapshot.today.cost))
          .font(.caption2.monospacedDigit().weight(.medium))
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

  private var placeholder: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(0..<3, id: \.self) { _ in
        HStack {
          Text("Provider")
            .font(.caption)
            .redacted(reason: .placeholder)
          Spacer()
          Text("--%")
            .font(.subheadline.monospacedDigit())
            .redacted(reason: .placeholder)
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .accessibilityLabel("Quota overview placeholder")
  }
}

struct OverviewLargeView: View {
  var entry: OverviewEntry

  var body: some View {
    let groups = OverviewWidgetContent.largeProviderGroups(
      from: entry.snapshot,
      configuredSelectionID: entry.configuredSelectionID
    )
    if entry.isPlaceholder {
      placeholder
    } else if let snapshot = entry.snapshot, !groups.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
          providerGroup(group)
        }
        Spacer(minLength: 0)
        todayFooter(snapshot: snapshot)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    } else {
      OverviewSmallView(entry: entry)
    }
  }

  private func providerGroup(_ group: WidgetProviderGroup) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(group.providerDisplayName)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
        Link(destination: OverviewWidgetContent.subscriptionURL(for: item)) {
          windowRow(item: item)
        }
        .tint(Color.primary)
      }
    }
  }

  private func windowRow(item: WidgetQuotaItem) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(item.windowTitle)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
        Spacer(minLength: 4)
        Text(OverviewWidgetContent.remainingLabel(for: item))
          .font(.subheadline.monospacedDigit().weight(.semibold))
          .foregroundStyle(overviewEmphasisColor(for: item))
          .widgetAccentable()
          .lineLimit(1)
          .minimumScaleFactor(0.65)
      }
      if OverviewWidgetContent.showsPercentMeter(item) {
        Gauge(value: item.remainingPercent, in: 0...100) { EmptyView() }
          .gaugeStyle(.linearCapacity)
          // The rows carry no tint of their own, so the meter names its own fill.
          .tint(Color.secondary)
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
        fetchedAt: nil,
        now: entry.date
      )
    )
  }

  private func todayFooter(snapshot: WidgetSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 2) {
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
        .minimumScaleFactor(0.85)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Today, \(OverviewWidgetContent.todayTokensAccessibility(input: snapshot.today.inputTokens, output: snapshot.today.outputTokens)), \(OverviewWidgetContent.costAccessibility(for: snapshot.today.cost)), \(OverviewWidgetContent.updated(fetchedAt: snapshot.fetchedAt, now: entry.date))"
    )
  }

  private var placeholder: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(0..<3, id: \.self) { _ in
        VStack(alignment: .leading, spacing: 4) {
          Text("Provider")
            .font(.caption)
            .redacted(reason: .placeholder)
          Text("Window  --%")
            .font(.subheadline)
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
    if let item = OverviewWidgetContent.lockScreenWeeklyItem(
      from: entry.snapshot,
      configuredSelectionID: entry.configuredSelectionID
    ), !entry.isPlaceholder {
      Group {
        if OverviewWidgetContent.showsPercentMeter(item) {
          usedGauge(item)
        } else {
          balanceContent(item)
        }
      }
      .accessibilityLabel(lockScreenAccessibility(item: item, now: entry.date))
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

  /// `accessoryCircularCapacity` keeps the ring and the centered percent; the window title
  /// does not fit this family and is left to the accessibility label.
  private func usedGauge(_ item: WidgetQuotaItem) -> some View {
    Gauge(value: item.usedPercent, in: 0...100) {
      Text(item.windowTitle)
    } currentValueLabel: {
      Text(OverviewWidgetContent.usedPercentLabel(for: item))
        .font(.system(.body, design: .rounded).monospacedDigit().weight(.semibold))
        .foregroundStyle(overviewEmphasisColor(for: item))
        .minimumScaleFactor(0.45)
        .lineLimit(1)
        .widgetAccentable()
    }
    .gaugeStyle(.accessoryCircularCapacity)
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
    let weekly = OverviewWidgetContent.lockScreenWeeklyItem(
      from: entry.snapshot,
      configuredSelectionID: entry.configuredSelectionID
    )
    let second = OverviewWidgetContent.lockScreenSecondItem(
      from: entry.snapshot,
      configuredSelectionID: entry.configuredSelectionID
    )
    if let weekly, !entry.isPlaceholder {
      VStack(alignment: .leading, spacing: 1) {
        weeklyRow(weekly)
        if let second {
          secondWindowRow(second)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        rectangularAccessibility(weekly: weekly, second: second, now: entry.date)
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

  /// The focused window on its own line, its reset under it: the family is too narrow to
  /// hold both side by side without truncating the reset.
  @ViewBuilder
  private func weeklyRow(_ item: WidgetQuotaItem) -> some View {
    Text("\(item.windowTitle) \(OverviewWidgetContent.usedPercentLabel(for: item))")
      .font(.headline.monospacedDigit())
      .foregroundStyle(overviewEmphasisColor(for: item))
      .widgetAccentable()
      .lineLimit(1)
      .minimumScaleFactor(0.65)
    if let resetsAt = item.resetsAt,
      let reset = overviewResetText(resetsAt: resetsAt, now: entry.date)
    {
      reset
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
  }

  private func secondWindowRow(_ item: WidgetQuotaItem) -> some View {
    var line = Text("\(item.windowTitle) \(OverviewWidgetContent.usedPercentLabel(for: item))")
    if let resetsAt = item.resetsAt,
      let reset = overviewResetText(resetsAt: resetsAt, now: entry.date)
    {
      line = line + Text(" · ") + reset
    }
    return line
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
  }

  private func rectangularAccessibility(
    weekly: WidgetQuotaItem,
    second: WidgetQuotaItem?,
    now: Date
  ) -> String {
    var parts = [lockScreenAccessibility(item: weekly, now: now)]
    if let second {
      parts.append(lockScreenAccessibility(item: second, now: now))
    }
    return parts.joined(separator: ", ")
  }
}

struct OverviewInlineView: View {
  var entry: OverviewEntry

  var body: some View {
    if let item = OverviewWidgetContent.lockScreenWeeklyItem(
      from: entry.snapshot,
      configuredSelectionID: entry.configuredSelectionID
    ), !entry.isPlaceholder {
      inlineText(item)
        .widgetAccentable()
        .accessibilityLabel(lockScreenAccessibility(item: item, now: entry.date))
    } else {
      Text(entry.isPlaceholder ? "Quota --%" : "Quota —")
        .accessibilityLabel(
          entry.isPlaceholder ? "Quota overview placeholder" : "Quota overview, no data yet"
        )
    }
  }

  private func inlineText(_ item: WidgetQuotaItem) -> Text {
    let used = OverviewWidgetContent.usedPercentLabel(for: item)
    var result = Text("\(item.windowTitle) \(used)")
    if let resetsAt = item.resetsAt,
      let reset = overviewResetText(resetsAt: resetsAt, now: entry.date)
    {
      result = result + Text(" · ") + reset
    }
    return result
  }
}

enum OverviewWidgetPreviewFixtures {
  static let now = Date(timeIntervalSince1970: 1_786_723_200)  // 2026-08-14T16:00:00Z

  static let contentSnapshot = WidgetSnapshot(
    fetchedAt: now.addingTimeInterval(-900),
    items: [
      WidgetQuotaItem(
        selectionID: "aaaaaaaaaaaa",
        providerID: "codex",
        providerDisplayName: "Codex",
        windowTitle: "5 Hours",
        remainingPercent: 18,
        hasLimit: true,
        resetsAt: now.addingTimeInterval(2_700),
        pace: .runsOut(
          QuotaPaceProjection(tempo: .ahead, deltaPercent: 42, projectedAtReset: 142),
          exhaustsAt: now.addingTimeInterval(1_800)
        )
      ),
      WidgetQuotaItem(
        selectionID: "aaaaaaaaaaaa",
        providerID: "codex",
        providerDisplayName: "Codex",
        windowTitle: "Weekly",
        remainingPercent: 40,
        hasLimit: true,
        resetsAt: now.addingTimeInterval(200_000)
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
        selectionID: "bbbbbbbbbbbb",
        providerID: "claude",
        providerDisplayName: "Claude Code",
        windowTitle: "Weekly",
        remainingPercent: 71,
        hasLimit: true,
        resetsAt: now.addingTimeInterval(250_000)
      ),
      WidgetQuotaItem(
        selectionID: "cccccccccccc",
        providerID: "grok",
        providerDisplayName: "Grok",
        windowTitle: "Weekly",
        remainingPercent: 81,
        hasLimit: true,
        resetsAt: now.addingTimeInterval(180_000)
      ),
      WidgetQuotaItem(
        selectionID: "dddddddddddd",
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

func lockScreenAccessibility(item: WidgetQuotaItem, now: Date = Date()) -> String {
  var parts = [OverviewWidgetContent.usedAccessibility(for: item)]
  if OverviewWidgetContent.paceRunsOut(item) {
    parts.append("runs out")
  }
  if let state = item.stateLabel(now: now) {
    parts.append(state)
  }
  if let resetsAt = item.resetsAt,
    let reset = FreshnessCopy.resetCopy(resetsAt: resetsAt, now: now)
  {
    parts.append(reset)
  }
  return parts.joined(separator: ", ")
}
