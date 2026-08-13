import AppKit
import SwiftUI

struct SettingsDiagnosticsView: View {
  @Bindable var model: MenuBarViewModel

  @State private var report: LocalServiceDiagnosticReport?
  @State private var errorMessage: String?
  @State private var isLoading = false
  @State private var copiedFormat: Format?

  private enum Format: String {
    case text
    case json

    var label: String {
      rawValue.uppercased()
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        Text("Diagnostics covers providers, quota, Usage, pricing, account, and sync.")
          .quotaSecondaryStyle()
          .fixedSize(horizontal: false, vertical: true)

        if isLoading {
          ProgressView("Collecting diagnostics…")
            .controlSize(.small)
        } else if let report {
          statusView(report)
          actionRow(report)
          componentsView(report)
          issuesView(report)
        } else if let errorMessage {
          VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
            Label(errorMessage, systemImage: "exclamationmark.circle")
              .quotaMetaStyle()
              .fixedSize(horizontal: false, vertical: true)
            Button("Retry") {
              Task { await load() }
            }
            .buttonStyle(QuotaPrimaryButtonStyle(isCompact: true))
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
    .task { await load() }
  }

  private func statusView(_ report: LocalServiceDiagnosticReport) -> some View {
    HStack(spacing: QuotaDesign.Spacing.sm) {
      Image(systemName: report.status == .healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(report.status == .healthy ? QuotaPalette.accent : QuotaPalette.critical)
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        Text(report.status.rawValue.capitalized)
          .quotaFont(.rowTitle)
        Text("Generated \(CompactAgeFormatter.string(since: report.generatedAt, now: Date())) ago")
          .quotaMetaStyle()
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Diagnostics status: \(report.status.rawValue)")
  }

  private func actionRow(_ report: LocalServiceDiagnosticReport) -> some View {
    HStack(spacing: QuotaDesign.Spacing.sm) {
      Button(copiedFormat == .text ? "Copied" : "Copy Text") {
        copy(report.textReport, format: .text)
      }
      .buttonStyle(QuotaPrimaryButtonStyle(isCompact: true))

      Button(copiedFormat == .json ? "Copied" : "Copy JSON") {
        copy(report.jsonReport, format: .json)
      }
      .buttonStyle(QuotaSecondaryButtonStyle())
    }
    .accessibilityElement(children: .contain)
  }

  private func componentsView(_ report: LocalServiceDiagnosticReport) -> some View {
    SettingsSection(title: "Components") {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(report.components, id: \.name) { component in
          SettingsListRow(
            title: component.name.capitalized,
            subtitle: componentSubtitle(component),
            systemImage: symbol(for: component.name)
          ) {
            Text(component.status.rawValue)
              .quotaListSecondaryStyle()
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(componentAccessibilityLabel(component))
        }
      }
    }
  }

  @ViewBuilder
  private func issuesView(_ report: LocalServiceDiagnosticReport) -> some View {
    if !report.issues.isEmpty {
      SettingsSection(title: "Issues") {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
            SettingsListRow(
              title: "\(issue.component.capitalized) · \(issue.code)",
              subtitle: issue.message,
              systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle"
            ) {
              VStack(alignment: .trailing, spacing: QuotaDesign.Spacing.xxs) {
                Text(issue.severity.rawValue)
                  .quotaListSecondaryStyle()
                Text("×\(issue.count)")
                  .quotaMonoListValueStyle()
              }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(issueAccessibilityLabel(issue))
          }
        }
      }
    }
  }

  private func symbol(for name: String) -> String {
    switch name {
    case "providers": "square.grid.2x2"
    case "quota": "gauge.with.dots.needle.67percent"
    case "usage": "chart.bar.xaxis"
    case "pricing": "tag"
    case "account": "person.crop.circle"
    case "sync": "arrow.triangle.2.circlepath"
    default: "questionmark.circle"
    }
  }

  private func metricsString(_ metrics: [String: Int]) -> String? {
    guard !metrics.isEmpty else { return nil }
    return metrics.keys.sorted().compactMap { key in
      guard let value = metrics[key] else { return nil }
      return "\(key)=\(value)"
    }.joined(separator: ", ")
  }

  private func componentSubtitle(_ component: LocalServiceDiagnosticComponent) -> String? {
    let values = [component.message, metricsString(component.metrics)].compactMap { $0 }
    return values.isEmpty ? nil : values.joined(separator: " · ")
  }

  private func componentAccessibilityLabel(_ component: LocalServiceDiagnosticComponent) -> String {
    var label = "\(component.name) \(component.status.rawValue)"
    if let message = component.message {
      label += ". \(message)"
    }
    if let metrics = metricsString(component.metrics) {
      label += ". \(metrics)"
    }
    return label
  }

  private func issueAccessibilityLabel(_ issue: LocalServiceDiagnosticIssue) -> String {
    "\(issue.severity.rawValue) in \(issue.component), \(issue.code), \(issue.count) occurrences. \(issue.message)"
  }

  private func load() async {
    guard report == nil, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      report = try await model.diagnose()
      errorMessage = nil
    } catch {
      errorMessage = (error as? LocalizedError)?.errorDescription ?? "Could not collect diagnostics."
    }
  }

  private func copy(_ value: String, format: Format) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    copiedFormat = format
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      if copiedFormat == format {
        copiedFormat = nil
      }
    }
  }
}
