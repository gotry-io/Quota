import AppKit
import QuotaWire
import SwiftUI

/// Pure labels and feedback timing for the Diagnostics page's header action and Copy Report row.
enum DiagnosticsHeaderAction {
  static let recheckLabel = "Recheck"
  static let checkingLabel = "Checking"
  static let copyFeedbackDuration: Duration = .seconds(2)

  static func recheckAccessibilityLabel(isChecking: Bool) -> String {
    isChecking ? checkingLabel : recheckLabel
  }

  static func copyAccessibilityLabel(didCopy: Bool) -> String {
    didCopy ? "Report copied" : "Copy report"
  }
}

/// The Diagnostics page's own presentation. Every sentence a person reads comes from the
/// service; this only decides which symbol and colour carries it.
enum DiagnosticsPresentation {
  /// The word for something this build does not have a name for. It is deliberately not the id:
  /// a wire id with its underscores swapped for spaces is the private service's vocabulary in a
  /// disguise, and the service's own sentence underneath already says what the row is about.
  static let unnamed = "Other"

  static func surfaceTitle(_ id: String) -> String {
    switch id {
    case "quota_overview": "Quota Overview"
    case "usage_this_device": "This Mac Usage"
    case "usage_account": "Account Usage"
    case "account": "Account"
    default: unnamed
    }
  }

  /// `provider:codex` with the `chatgpt_usage_api` rung reads as "Codex · OAuth".
  ///
  /// Every part of that comes from a table: the provider catalog, the Usage agent list, the
  /// service-owned paths below, and the collection report's own source names. None of it is
  /// derived from the id it arrived as.
  static func sourceTitle(subject: String, sourceID: String?) -> String {
    let name = subjectTitle(subject)
    guard let sourceID else { return name }
    return "\(name) · \(QuotaCollectionSource.displayName(forSourceID: sourceID))"
  }

  private static func subjectTitle(_ subject: String) -> String {
    let parts = subject.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else { return serviceSubjectTitle(subject) }
    let identity = String(parts[1])
    switch parts[0] {
    case "provider":
      // An id outside the catalog is `.unknown`, which names itself the same way everywhere.
      return (ProviderID(rawValue: identity) ?? .unknown(identity)).displayName
    case "agent":
      return BillingAgent(rawValue: identity).map(UsageValueFormatter.agent) ?? unnamed
    default:
      return unnamed
    }
  }

  /// The service's own paths, which belong to no provider and no agent.
  private static func serviceSubjectTitle(_ subject: String) -> String {
    switch subject {
    case "account": "Account"
    case "usage_upload": "Usage sync"
    case "quota_upload": "Quota sync"
    case "pricing_catalog": "Pricing"
    case "provider_configuration": "Provider setup"
    case "local_state": "Local data"
    default: unnamed
    }
  }

  /// When the report on screen was evaluated, as a clock time rather than an age.
  ///
  /// Every other past instant in the product is a relative age, because a quota number that
  /// moves while it is being read is noise. A check is the opposite: a person presses Recheck
  /// and needs to see that what is on screen came from the run they just asked for, and "just
  /// now" says that about every run. The time is fixed — it does not depend on when it is
  /// read — and locale-shortened, so it reads the way the menu bar clock beside it does.
  static func checkedLabel(
    _ generatedAt: Date,
    locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> String {
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    style.timeZone = timeZone
    return "Checked \(generatedAt.formatted(style.locale(locale)))"
  }

  static func statusLabel(_ status: LocalServiceDiagnosticStatus) -> String {
    switch status {
    case .ok: "Working"
    case .degraded: "Needs attention"
    case .blocked: "Unavailable"
    case .inactive: "Off"
    }
  }

  static func dataLabel(_ data: LocalServiceDiagnosticDataState) -> String {
    switch data {
    case .current: "Current data"
    case .stale: "Saved data is stale"
    case .partial: "Some data is incomplete"
    case .empty: "No data yet"
    }
  }

  static func summaryLabel(_ summary: LocalServiceDiagnosticSummary) -> String {
    switch (summary.operation, summary.attention) {
    case (.blocked, _): "Action needed"
    case (.degraded, _), (_, .required): "Some checks need attention"
    default: "All systems working"
    }
  }

  static func symbol(forSurface id: String) -> String {
    switch id {
    case "quota_overview": "gauge.with.dots.needle.67percent"
    case "usage_this_device": "laptopcomputer"
    case "usage_account": "cloud"
    case "account": "person.crop.circle"
    default: "questionmark.circle"
    }
  }
}

/// Owns Diagnostics page state so MenuBarContentView can drive header actions.
enum DiagnosticsPageState: Equatable {
  case loading
  case error(String)
  case report(LocalServiceDiagnosticReport, isRechecking: Bool, refreshWarning: String?)
}

@MainActor
@Observable
final class DiagnosticsPageModel {
  private(set) var report: LocalServiceDiagnosticReport?
  private(set) var errorMessage: String?
  private(set) var isLoading = false
  private(set) var didCopy = false

  private var copyFeedbackTask: Task<Void, Never>?
  /// Bumped on entry reset so an abandoned in-flight check cannot publish stale results.
  private var loadGeneration = 0

  init(
    report: LocalServiceDiagnosticReport? = nil,
    errorMessage: String? = nil,
    isLoading: Bool = false
  ) {
    self.report = report
    self.errorMessage = errorMessage
    self.isLoading = isLoading
  }

  var pageState: DiagnosticsPageState {
    if let report {
      return .report(report, isRechecking: isLoading, refreshWarning: errorMessage)
    }
    if isLoading || errorMessage == nil { return .loading }
    return .error(errorMessage ?? "Could not collect diagnostics.")
  }

  var showsHeaderActions: Bool { report != nil }
  var canRecheck: Bool { report != nil && !isLoading }

  func prepareForEntry() {
    loadGeneration += 1
    copyFeedbackTask?.cancel()
    copyFeedbackTask = nil
    report = nil
    errorMessage = nil
    isLoading = false
    didCopy = false
  }

  /// Runs a fresh `diagnose` check. Ignores overlapping calls while loading.
  func runCheck(diagnose: () async throws -> LocalServiceDiagnosticReport) async {
    guard !isLoading else { return }
    let generation = loadGeneration
    isLoading = true
    errorMessage = nil
    defer {
      if generation == loadGeneration {
        isLoading = false
      }
    }
    do {
      let next = try await diagnose()
      guard generation == loadGeneration else { return }
      report = next
      errorMessage = nil
    } catch {
      guard generation == loadGeneration else { return }
      errorMessage =
        (error as? LocalizedError)?.errorDescription ?? "Could not collect diagnostics."
    }
  }

  func copyTextReport() {
    guard let text = report?.textReport else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    didCopy = true
    copyFeedbackTask?.cancel()
    copyFeedbackTask = Task { @MainActor in
      try? await Task.sleep(for: DiagnosticsHeaderAction.copyFeedbackDuration)
      guard !Task.isCancelled else { return }
      didCopy = false
    }
  }
}

struct SettingsDiagnosticsView: View {
  let state: DiagnosticsPageState
  @Bindable var model: DiagnosticsPageModel
  let onRetry: () -> Void

  var body: some View {
    QuotaNavigationStableContent(state: state) { presentedState in
      content(presentedState)
    }
  }

  @ViewBuilder
  private func content(_ state: DiagnosticsPageState) -> some View {
    switch state {
    case .loading:
      QuotaPageStateView(loadingTitle: "Checking…")
    case .error(let errorMessage):
      QuotaPageStateView(
        errorTitle: "Diagnostics Unavailable",
        message: errorMessage,
        retry: onRetry
      )
    case .report(let report, _, let refreshWarning):
      VStack(spacing: 0) {
        if let refreshWarning {
          QuotaInlineNotice(message: refreshWarning)
            .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
            .padding(.top, QuotaDesign.Spacing.sm)
        }

        ScrollView {
          VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
            statusView(report)
            surfacesView(report)
            sourcesView(report)
            reportView()
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
          .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
        }
      }
    }
  }

  private func statusView(_ report: LocalServiceDiagnosticReport) -> some View {
    let checked = DiagnosticsPresentation.checkedLabel(report.generatedAt)
    let label = DiagnosticsPresentation.summaryLabel(report.summary)
    return HStack(spacing: QuotaDesign.Spacing.sm) {
      Image(systemName: summarySymbol(report.summary))
        .foregroundStyle(summaryColor(report.summary))
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        Text(label)
          .quotaFont(.rowTitle)
        Text(checked)
          .quotaMetaStyle()
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Status: \(label). \(checked)")
  }

  private func surfacesView(_ report: LocalServiceDiagnosticReport) -> some View {
    SettingsSection(title: "Data") {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(report.surfaces) { surface in
          SettingsListRow(
            title: DiagnosticsPresentation.surfaceTitle(surface.id),
            subtitle: surface.message,
            systemImage: DiagnosticsPresentation.symbol(forSurface: surface.id)
          ) {
            Image(systemName: statusSymbol(surface.status, data: surface.data))
              .quotaFont(.secondary)
              .foregroundStyle(statusColor(surface.status, data: surface.data))
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "\(DiagnosticsPresentation.surfaceTitle(surface.id)), "
              + "\(DiagnosticsPresentation.statusLabel(surface.status)), "
              + "\(DiagnosticsPresentation.dataLabel(surface.data)). \(surface.message)"
          )
        }
      }
    }
  }

  @ViewBuilder
  private func sourcesView(_ report: LocalServiceDiagnosticReport) -> some View {
    if !report.sources.isEmpty {
      SettingsSection(title: "Sources") {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(report.sources.enumerated()), id: \.offset) { _, source in
            let title = DiagnosticsPresentation.sourceTitle(
              subject: source.subject, sourceID: source.sourceID)
            HStack(alignment: .top, spacing: QuotaDesign.Spacing.sm) {
              Image(systemName: statusSymbol(source.status, data: .current))
                .quotaFont(.secondary)
                .foregroundStyle(statusColor(source.status, data: .current))
                .frame(
                  width: QuotaDesign.Layout.settingsIconColumnWidth,
                  height: QuotaDesign.Layout.settingsIconColumnWidth
                )
              VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
                Text(title)
                  .quotaSettingsLabelStyle()
                  .fixedSize(horizontal: false, vertical: true)
                Text(source.message)
                  .quotaListSecondaryStyle()
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
            .padding(.vertical, QuotaDesign.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
              "\(title), \(DiagnosticsPresentation.statusLabel(source.status)). \(source.message)"
            )
          }
        }
      }
    }
  }

  /// The text report is the page plus the recent work the page does not list, for a support
  /// conversation; it is copied from here because here is where the report exists.
  private func reportView() -> some View {
    SettingsSection(title: "Report") {
      Button(action: { model.copyTextReport() }) {
        SettingsListRow(
          title: model.didCopy ? "Report Copied" : "Copy Report",
          systemImage: "doc.on.doc"
        ) {
          EmptyView()
        }
      }
      .buttonStyle(QuotaListRowButtonStyle())
      .accessibilityLabel(DiagnosticsHeaderAction.copyAccessibilityLabel(didCopy: model.didCopy))
    }
  }

  private func summarySymbol(_ summary: LocalServiceDiagnosticSummary) -> String {
    switch (summary.operation, summary.attention) {
    case (.blocked, _): "xmark.octagon.fill"
    case (.degraded, _), (_, .required): "exclamationmark.triangle.fill"
    default: "checkmark.circle.fill"
    }
  }

  private func summaryColor(_ summary: LocalServiceDiagnosticSummary) -> Color {
    switch (summary.operation, summary.attention) {
    case (.blocked, _): QuotaPalette.critical
    case (.degraded, _), (_, .required): QuotaPalette.warning
    default: QuotaPalette.accent
    }
  }

  private func statusSymbol(
    _ status: LocalServiceDiagnosticStatus,
    data: LocalServiceDiagnosticDataState
  ) -> String {
    if data == .partial || data == .stale { return "exclamationmark.triangle.fill" }
    return switch status {
    case .ok: "checkmark.circle.fill"
    case .inactive: "minus.circle"
    case .degraded: "exclamationmark.triangle.fill"
    case .blocked: "xmark.octagon.fill"
    }
  }

  private func statusColor(
    _ status: LocalServiceDiagnosticStatus,
    data: LocalServiceDiagnosticDataState
  ) -> Color {
    if data == .partial || data == .stale { return QuotaPalette.warning }
    return switch status {
    case .ok: QuotaPalette.accent
    case .inactive: QuotaPalette.body
    case .degraded: QuotaPalette.warning
    case .blocked: QuotaPalette.critical
    }
  }
}
