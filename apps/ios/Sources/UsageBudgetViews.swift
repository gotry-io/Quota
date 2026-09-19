import QuotaPresentation
import SwiftUI

/// This month's spend against the budget, at the top of Usage.
///
/// The budget is a preference of this iPhone and is never uploaded, so the row says nothing when
/// none is set beyond offering to set one.
struct UsageBudgetSection: View {
  @Bindable var model: AppModel
  @Binding var editing: Bool

  var body: some View {
    QuotaCard(
      title: "Monthly budget",
      titleIdentifier: "section.header.budget",
      trailing: {
        Button(model.usage.budget.isSet ? "Edit budget" : "Set budget") { editing = true }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("usage.budget.edit")
      }
    ) {
      if let progress = model.usage.budgetProgress {
        VStack(alignment: .leading, spacing: 8) {
          QuotaMeter(fraction: progress.fraction, tone: Self.tone(for: progress))
          Text(progress.text)
            .font(QuotaDesign.Typography.support.monospacedDigit())
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Monthly budget")
        .accessibilityValue(progress.accessibilityText)
        .accessibilityIdentifier("usage.budget")
      } else {
        Text("No budget is set for this month.")
          .font(.body)
          .foregroundStyle(Color.primary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("usage.budget.empty")
      }
    }
  }

  /// Budget is spend, not remaining: map the crossings without `QuotaTone.remaining`.
  private static func tone(for progress: UsageBudgetProgress) -> QuotaTone {
    if progress.percent >= UsageBudget.exhaustedPercent { return .critical }
    if progress.percent >= UsageBudget.warningPercent { return .warning }
    return .healthy
  }
}

/// Sets the amount and whether crossing 80% and 100% of it posts a notification.
struct UsageBudgetEditor: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var amount = ""
  @State private var alerts = true

  var body: some View {
    NavigationStack {
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
    }
    .onAppear {
      amount = model.usage.budget.amountUSD.map(UsageBudgetProgress.plain) ?? ""
      alerts = model.usage.budget.alerts
    }
  }
}

/// Picks the two dates a custom period covers, no wider than the year the activity read answered.
struct UsageRangeEditor: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
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
    let earliest = UsageDateText.date(from: model.usage.usageEarliestDay) ?? Date()
    let latest = UsageDateText.date(from: model.usage.activityToday) ?? Date()
    return earliest...max(earliest, latest)
  }
}
