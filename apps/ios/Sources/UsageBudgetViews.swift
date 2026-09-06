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
    Section {
      if let progress = model.budgetProgress {
        VStack(alignment: .leading, spacing: 8) {
          ProgressView(value: progress.fraction)
            .tint(.primary)
          Text(progress.text)
            .font(.body.monospacedDigit())
            .foregroundStyle(Color.primary)
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
      Button(model.budget.isSet ? "Edit budget" : "Set budget") { editing = true }
        .tint(.primary)
        .accessibilityIdentifier("usage.budget.edit")
    } header: {
      Text("Monthly budget")
        .accessibilityIdentifier("section.header.budget")
    }
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
            model.setBudget(
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
      amount = model.budget.amountUSD.map(UsageBudgetProgress.plain) ?? ""
      alerts = model.budget.alerts
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
            model.selectUsagePeriod(
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
      let range = model.usagePeriodRange
      from = range.flatMap { UsageDateText.date(from: $0.from) } ?? bounds.upperBound
      to = range.flatMap { UsageDateText.date(from: $0.to) } ?? bounds.upperBound
    }
  }

  private var bounds: ClosedRange<Date> {
    let earliest = UsageDateText.date(from: model.usageEarliestDay) ?? Date()
    let latest = UsageDateText.date(from: model.activityToday) ?? Date()
    return earliest...max(earliest, latest)
  }
}
