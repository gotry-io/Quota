import QuotaPresentation
import SwiftUI

/// Compact Usage-root label: progress meter and remaining, only drawn when a budget is set.
struct UsageBudgetRowLabel: View {
  let progress: UsageBudgetProgress?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("Monthly budget")
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
            .accessibilityIdentifier("usage.budget")
          Spacer(minLength: 8)
          if let progress {
            remainingText(progress)
          }
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("Monthly budget")
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
            .accessibilityIdentifier("usage.budget")
          if let progress {
            remainingText(progress)
          }
        }
      }
      if let progress {
        QuotaMeter(fraction: progress.fraction, tone: UsageBudgetCopy.tone(for: progress))
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Monthly budget")
    .accessibilityValue(progress.map(UsageBudgetCopy.accessibility) ?? "Set")
  }

  private func remainingText(_ progress: UsageBudgetProgress) -> some View {
    Text(UsageBudgetCopy.remaining(progress))
      .foregroundStyle(QuotaTheme.secondary)
      .font(QuotaDesign.Typography.support.monospacedDigit())
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityHidden(true)
      .accessibilityIdentifier("usage.budget")
  }
}

/// The budget destination: meter, remaining, and the existing editor.
struct UsageBudgetDetail: View {
  @Bindable var model: AppModel
  @Binding var editing: Bool

  var body: some View {
    List {
      Section {
        UsageBudgetSection(model: model, editing: $editing)
          .quotaCardRow()
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Monthly budget")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("usage.budget.detail")
  }
}

/// This month's spend against the budget.
///
/// The budget is a preference of this iPhone and is never uploaded. Usage shows this only when
/// a budget is set; **Set a monthly budget** lives in Settings.
struct UsageBudgetSection: View {
  @Bindable var model: AppModel
  @Binding var editing: Bool

  var body: some View {
    QuotaCard(
      title: "Monthly budget",
      titleIdentifier: "section.header.budget",
      trailing: {
        Button("Edit budget") { editing = true }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("usage.budget.edit")
      }
    ) {
      if let progress = model.usage.budgetProgress {
        VStack(alignment: .leading, spacing: 8) {
          QuotaMeter(fraction: progress.fraction, tone: UsageBudgetCopy.tone(for: progress))
          Text(UsageBudgetCopy.progressAndRemaining(progress))
            .font(QuotaDesign.Typography.support.monospacedDigit())
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Monthly budget")
        .accessibilityValue(UsageBudgetCopy.accessibility(progress))
      } else {
        Text("This month's spend is not available yet.")
          .font(.body)
          .foregroundStyle(Color.primary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

enum UsageBudgetCopy {
  static func remainingUSD(_ progress: UsageBudgetProgress) -> Decimal {
    max(0, progress.budgetUSD - progress.spentUSD)
  }

  static func remaining(_ progress: UsageBudgetProgress) -> String {
    "\(UsageBudgetProgress.usd(remainingUSD(progress))) remaining"
  }

  static func progressAndRemaining(_ progress: UsageBudgetProgress) -> String {
    let spent = UsageBudgetProgress.usd(progress.spentUSD)
    let budget = UsageBudgetProgress.usd(progress.budgetUSD)
    let prefix = progress.partial ? "≥ " : ""
    return "\(prefix)\(spent) of \(budget) · \(remaining(progress))"
  }

  static func accessibility(_ progress: UsageBudgetProgress) -> String {
    "\(progress.accessibilityText), \(remaining(progress))"
  }

  /// Budget is spend, not remaining: map the crossings without `QuotaTone.remaining`.
  static func tone(for progress: UsageBudgetProgress) -> QuotaTone {
    if progress.percent >= UsageBudget.exhaustedPercent { return .critical }
    if progress.percent >= UsageBudget.warningPercent { return .warning }
    return .healthy
  }
}

/// The budget editor fields. A sheet wraps this in a `NavigationStack`; Settings pushes it.
struct UsageBudgetEditorPage: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var amount = ""
  @State private var alerts = true

  var body: some View {
    Form {
      Section {
        TextField("No budget", text: $amount)
          .keyboardType(.decimalPad)
          .accessibilityIdentifier("usage.budget.amount")
      } header: {
        Text("Amount in USD")
      }
      Section {
        Toggle("Tell me at 80% and 100%", isOn: $alerts)
          .tint(.primary)
          .accessibilityIdentifier("usage.budget.alerts")
      }
    }
    .navigationTitle("Monthly budget")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          model.usage.setBudget(
            UsageBudget(
              amountUSD: Decimal(string: amount, locale: .current),
              alerts: alerts
            )
          )
          dismiss()
        }
        .accessibilityIdentifier("usage.budget.save")
      }
    }
    .onAppear {
      amount = model.usage.budget.amountUSD.map(UsageBudgetProgress.plain) ?? ""
      alerts = model.usage.budget.alerts
    }
  }
}

/// Sets the amount and whether crossing 80% and 100% of it posts a notification.
struct UsageBudgetEditor: View {
  @Bindable var model: AppModel

  var body: some View {
    NavigationStack {
      UsageBudgetEditorPage(model: model)
    }
  }
}

/// Picks the two dates a custom period covers, no wider than the year the activity read answered.
struct UsageRangeEditor: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.displayClock) private var displayClock
  @State private var from = Date()
  @State private var to = Date()

  var body: some View {
    NavigationStack {
      Form {
        DatePicker("From", selection: $from, in: bounds, displayedComponents: .date)
          .accessibilityIdentifier("usage.range.from")
        DatePicker("To", selection: $to, in: bounds, displayedComponents: .date)
          .accessibilityIdentifier("usage.range.to")
      }
      .navigationTitle("Custom range")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Apply") {
            model.usage.selectUsagePeriod(
              .custom(
                from: UsageDateText.date(min(from, to)),
                to: UsageDateText.date(max(from, to))
              )
            )
            dismiss()
          }
          .accessibilityIdentifier("usage.range.apply")
        }
      }
    }
    .onAppear {
      let range = model.usage.usagePeriodRange
      from = range.flatMap { UsageDateText.date(from: $0.from) } ?? bounds.upperBound
      to = range.flatMap { UsageDateText.date(from: $0.to) } ?? bounds.upperBound
    }
  }

  private var bounds: ClosedRange<Date> {
    let earliest = UsageDateText.date(from: model.usage.usageEarliestDay) ?? displayClock.now()
    let latest = UsageDateText.date(from: model.usage.activityToday) ?? displayClock.now()
    return earliest...max(earliest, latest)
  }
}
