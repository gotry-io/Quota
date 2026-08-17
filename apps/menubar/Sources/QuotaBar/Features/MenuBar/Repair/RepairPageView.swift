import SwiftUI

struct RepairPageView: View {
  let session: LocalServiceRepairSession
  let now: Date
  let onRetry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
      if session.status == .stuck || session.status == .failed {
        Image(systemName: "exclamationmark.circle")
          .font(QuotaDesign.Typography.emptyIcon)
          .foregroundStyle(QuotaPalette.critical)
          .accessibilityHidden(true)
      }

      if let title = session.title, !title.isEmpty {
        Text(title)
          .quotaFont(.emptyTitle)
          .foregroundStyle(QuotaPalette.ink)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let activity = session.activity, !activity.isEmpty {
        Text(activity)
          .quotaSecondaryStyle()
          .fixedSize(horizontal: false, vertical: true)
      }

      Text(RepairCopy.elapsed(from: session.startedAt, now: now))
        .quotaMetaStyle()

      if let heartbeat = RepairCopy.heartbeatAge(from: session.heartbeatAt, now: now) {
        Text(heartbeat)
          .quotaMetaStyle()
      }

      RepairProgressView(session: session)

      if let guidance = session.guidance, !guidance.isEmpty {
        Text(guidance)
          .quotaSecondaryStyle()
          .fixedSize(horizontal: false, vertical: true)
      }

      if session.status == .stuck || session.status == .failed {
        repairRecovery
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
    .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var repairRecovery: some View {
    switch session.recoveryAction {
    case .retry:
      Button("Retry", action: onRetry)
        .buttonStyle(QuotaPrimaryButtonStyle(isCompact: true))
        .accessibilityLabel("Retry repair")
    case .reinstall:
      Text("Reinstall QuotaBar to repair its local service.")
        .quotaSecondaryStyle()
        .fixedSize(horizontal: false, vertical: true)
    case nil:
      EmptyView()
    }
  }
}

struct RepairDerivedNotice: View {
  let session: LocalServiceRepairSession
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      if let title = session.title {
        Text(title)
          .quotaFont(.settingsLabel)
          .foregroundStyle(QuotaPalette.ink)
      }
      if let activity = session.activity {
        Text(activity)
          .quotaListSecondaryStyle()
      }
      Text(RepairCopy.elapsed(from: session.startedAt, now: now))
        .quotaMetaStyle()
      RepairProgressView(session: session)
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .padding(.vertical, QuotaDesign.Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaGroupSurface()
    .accessibilityElement(children: .combine)
  }
}

struct RepairProgressView: View {
  let session: LocalServiceRepairSession

  var body: some View {
    if let current = session.progressCurrent, let total = session.progressTotal, total > 0 {
      ProgressView(value: Double(current), total: Double(total))
        .progressViewStyle(.linear)
        .tint(QuotaPalette.accent)
        .accessibilityLabel("Repair progress")
        .accessibilityValue("\(current) of \(total)")
    } else if session.status == .repairing {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Repair in progress")
    }
  }
}

enum RepairCopy {
  static func elapsed(from startedAt: Date?, now: Date) -> String {
    guard let startedAt else { return "Elapsed —" }
    return "Elapsed \(secondsPhrase(Int(max(0, now.timeIntervalSince(startedAt)))))"
  }

  static func heartbeatAge(from heartbeatAt: Date?, now: Date) -> String? {
    guard let heartbeatAt else { return nil }
    let seconds = Int(max(0, now.timeIntervalSince(heartbeatAt)))
    guard seconds > 8 else { return nil }
    return "Updated \(secondsPhrase(seconds)) ago"
  }

  static func secondsPhrase(_ seconds: Int) -> String {
    if seconds == 1 { return "1 second" }
    if seconds < 60 { return "\(seconds) seconds" }
    let minutes = seconds / 60
    if minutes == 1 { return "1 minute" }
    return "\(minutes) minutes"
  }
}
