import Charts
import QuotaPresentation
import QuotaWire
import SwiftUI

/// Next resets (docs/design.md): the coming seven days in local time, one lane per current
/// subscription with a reset in them, a ring per reset instant in the band colour of the window
/// it refills (the lowest when several refill in the same minute), labelled with window titles.
/// The grouping is `NextResets.lanes`; its text alternative is each window's **Resets** line.
struct NextResetsSection: View {
  /// In the order the Quota tab lists them.
  let subscriptions: [QuotaSubscription]
  let now: Date
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private struct Mark: Identifiable {
    let lane: String
    let at: Date
    let titles: String
    let lowestRemainingPercent: Double?
    var id: String { "\(lane)|\(at.timeIntervalSince1970)" }
  }

  var body: some View {
    let marks = self.marks
    if !marks.isEmpty {
      Section {
        QuotaCard(title: "Next resets", titleIdentifier: "section.header.next-resets") {
          Group {
            if dynamicTypeSize.isAccessibilitySize {
              lines(marks)
            } else {
              chart(marks)
            }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Next resets, next 7 days, local time")
          .accessibilityValue(spoken(marks))
          .accessibilityIdentifier("overview.next-resets")
        }
        .quotaCardRow()
      }
    }
  }

  private var marks: [Mark] {
    let lanes = NextResets.lanes(
      in: subscriptions,
      isCurrent: { !$0.snapshot.isStale(now: now) },
      windows: { $0.snapshot.windows },
      now: now
    )
    let names = laneNames(lanes.map(\.subscription))
    return zip(lanes, names).flatMap { lane, name in
      lane.resets.map { reset in
        Mark(
          lane: name,
          at: reset.at,
          titles: reset.windows.map(QuotaFormat.windowTitle).joined(separator: " · "),
          lowestRemainingPercent: reset.lowestRemainingPercent
        )
      }
    }
  }

  /// A lane is its provider; a second account of the same provider adds its masked label so the
  /// two lanes are told apart.
  private func laneNames(_ subscriptions: [QuotaSubscription]) -> [String] {
    let counts = Dictionary(grouping: subscriptions, by: \.snapshot.provider).mapValues(\.count)
    return subscriptions.enumerated().map { index, subscription in
      let provider = subscription.snapshot.provider
      guard (counts[provider] ?? 0) > 1 else { return provider.displayName }
      let label =
        PlanDisplay.accountLabel(subscription.snapshot.account.label) ?? "Account \(index + 1)"
      return "\(provider.displayName) · \(label)"
    }
  }

  private func chart(_ marks: [Mark]) -> some View {
    let laneCount = Set(marks.map(\.lane)).count
    return Chart(marks) { mark in
      PointMark(x: .value("Reset", mark.at), y: .value("Subscription", mark.lane))
        .symbol {
          Circle()
            .strokeBorder(color(mark), lineWidth: 2)
            .background(Circle().fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .frame(width: 11, height: 11)
        }
        .annotation(position: annotationPosition(mark), spacing: 4) {
          Text(mark.titles)
            .font(.caption2)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
        }
    }
    .chartXScale(domain: now...now.addingTimeInterval(NextResets.horizon))
    .chartXAxis {
      AxisMarks(values: .stride(by: .day)) { _ in
        AxisGridLine()
        AxisValueLabel(format: .dateTime.weekday(.abbreviated), anchor: .topLeading)
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { _ in
        AxisValueLabel()
          .font(.caption)
          .foregroundStyle(Color.primary)
      }
    }
    .frame(height: CGFloat(laneCount) * 40 + 28)
    .padding(.vertical, 4)
  }

  /// Near the far end a label sits before its ring rather than running off the plot.
  private func annotationPosition(_ mark: Mark) -> AnnotationPosition {
    mark.at.timeIntervalSince(now) > NextResets.horizon * 0.7 ? .leading : .trailing
  }

  /// At accessibility sizes the lanes are lines of text, which can wrap.
  private func lines(_ marks: [Mark]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(marks) { mark in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Circle()
            .strokeBorder(color(mark), lineWidth: 2)
            .frame(width: 11, height: 11)
          Text(line(mark))
            .font(.subheadline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func line(_ mark: Mark) -> String {
    let reset = QuotaFormat.resetTime(mark.at, now: now) ?? ""
    return "\(mark.lane) \(mark.titles) · \(reset)"
  }

  private func spoken(_ marks: [Mark]) -> String {
    marks.map { mark in
      "\(mark.lane) \(mark.titles), \(QuotaFormat.resetTime(mark.at, now: now) ?? "")"
    }
    .joined(separator: "; ")
  }

  private func color(_ mark: Mark) -> Color {
    guard let percent = mark.lowestRemainingPercent else { return QuotaTheme.secondary }
    return QuotaTheme.color(for: QuotaTone.remaining(percent: percent))
  }
}
