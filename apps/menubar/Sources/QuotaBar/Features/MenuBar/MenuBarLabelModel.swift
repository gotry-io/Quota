import Foundation
import QuotaPresentation
import QuotaWire

/// One status item's label and the identity macOS uses to keep its position.
struct MenuBarStatusItemSpec: Equatable, Sendable {
  let id: MenuBarStatusItemID
  let label: MenuBarLabelModel
}

/// The mark one cell wears: the provider the number belongs to, or Quota's own when there is
/// no number to attribute.
enum MenuBarLabelIcon: Equatable, Hashable, Sendable {
  case quota
  case provider(ProviderID)
}

/// One reading in the menu bar: a mark, a remaining percent, or both.
struct MenuBarLabelCell: Equatable, Hashable, Sendable {
  let icon: MenuBarLabelIcon?
  let text: String?
}

/// The menu-bar item's content: one or more readings composed into a template image.
///
/// The point of an item is that a remaining percent is readable without opening anything, so
/// each cell names a single reading rather than an average or a count. A reading that no
/// longer describes live quota answers for nothing: a lone item falls back to Quota's mark,
/// and a packed item keeps that provider's mark so the strip does not jump.
struct MenuBarLabelModel: Equatable, Hashable, Sendable {
  let cells: [MenuBarLabelCell]
  let accessibilityLabel: String

  var icon: MenuBarLabelIcon? { cells.count == 1 ? cells.first?.icon : nil }
  var text: String? { cells.count == 1 ? cells.first?.text : nil }

  init(icon: MenuBarLabelIcon?, text: String?, accessibilityLabel: String) {
    self.init(
      cells: [MenuBarLabelCell(icon: icon, text: text)],
      accessibilityLabel: accessibilityLabel
    )
  }

  init(cells: [MenuBarLabelCell], accessibilityLabel: String) {
    self.cells = cells
    self.accessibilityLabel = accessibilityLabel
  }

  static let empty = MenuBarLabelModel(
    icon: .quota,
    text: nil,
    accessibilityLabel: "QuotaBar"
  )

  /// One label, for callers that still answer a single item.
  static func make(
    overview: [LocalServiceOverviewItem],
    style: MenuBarStylePreference,
    provider: MenuBarProviderPreference,
    arrangement: MenuBarArrangementPreference = .combined,
    now: Date,
    visibleProviders: [ProviderID]? = nil
  ) -> MenuBarLabelModel {
    specs(
      overview: overview,
      style: style,
      provider: provider,
      arrangement: arrangement,
      visibleProviders: visibleProviders ?? provider.selected,
      now: now
    ).first?.label ?? .empty
  }

  static func specs(
    overview: [LocalServiceOverviewItem],
    style: MenuBarStylePreference,
    provider: MenuBarProviderPreference,
    arrangement: MenuBarArrangementPreference,
    visibleProviders: [ProviderID],
    now: Date
  ) -> [MenuBarStatusItemSpec] {
    specs(
      overview: overview,
      style: style,
      layout: .resolve(
        selection: provider,
        arrangement: arrangement,
        visibleProviders: visibleProviders
      ),
      now: now
    )
  }

  /// The status items the resolved layout should occupy, in Overview order.
  static func specs(
    overview: [LocalServiceOverviewItem],
    style: MenuBarStylePreference,
    layout: MenuBarLayout,
    now: Date
  ) -> [MenuBarStatusItemSpec] {
    let style = layout.effectiveStyle(style)
    switch layout {
    case .automatic:
      return [
        MenuBarStatusItemSpec(
          id: .automatic,
          label: label(overview: overview, style: style, allowed: nil, now: now)
        )
      ]
    case .packed(let providers):
      return [
        MenuBarStatusItemSpec(
          id: .combined,
          label: packedLabel(overview: overview, style: style, providers: providers, now: now)
        )
      ]
    case .items(let providers):
      return providers.map { id in
        MenuBarStatusItemSpec(
          id: .provider(id),
          label: label(overview: overview, style: style, allowed: id, now: now)
        )
      }
    }
  }

  private static func packedLabel(
    overview: [LocalServiceOverviewItem],
    style: MenuBarStylePreference,
    providers: [ProviderID],
    now: Date
  ) -> MenuBarLabelModel {
    var cells: [MenuBarLabelCell] = []
    var spoken: [String] = ["QuotaBar"]
    for id in providers {
      let part = label(
        overview: overview,
        style: style,
        allowed: id,
        absentIcon: .provider(id),
        now: now
      )
      cells.append(contentsOf: part.cells)
      if let text = part.text {
        spoken.append("\(id.displayName) \(text) remaining")
      } else {
        spoken.append(id.displayName)
      }
    }
    return MenuBarLabelModel(cells: cells, accessibilityLabel: spoken.joined(separator: ", "))
  }

  private static func label(
    overview: [LocalServiceOverviewItem],
    style: MenuBarStylePreference,
    allowed: ProviderID?,
    absentIcon: MenuBarLabelIcon = .quota,
    now: Date
  ) -> MenuBarLabelModel {
    if !style.showsPercent {
      return .empty
    }
    guard
      let tightest = tightestReading(
        in: overview,
        allowed: allowed.map { [$0] },
        now: now
      )
    else {
      return MenuBarLabelModel(icon: absentIcon, text: nil, accessibilityLabel: "QuotaBar")
    }
    let percent = RemainingQuotaFormat.percent(tightest.remainingPercent)
    return MenuBarLabelModel(
      icon: style.showsIcon ? .provider(tightest.provider) : nil,
      text: percent,
      accessibilityLabel: "QuotaBar, \(tightest.provider.displayName) \(percent) remaining"
    )
  }

  private struct Reading {
    let provider: ProviderID
    let remainingPercent: Double
  }

  /// The smallest remaining percent any window of any current reading reports, among the
  /// readings `allowed` names — or every current reading when `allowed` is nil.
  ///
  /// Balance-only windows carry no budget to be a percent of, so they cannot be the
  /// constraint; every other window can.
  private static func tightestReading(
    in overview: [LocalServiceOverviewItem],
    allowed: Set<ProviderID>?,
    now: Date
  ) -> Reading? {
    var tightest: Reading?
    for item in overview where isCurrent(item, now: now) {
      if let allowed, !allowed.contains(item.identity.provider) { continue }
      for window in item.snapshot.windows where window.showsPercentMeter {
        guard tightest.map({ window.remainingPercent < $0.remainingPercent }) ?? true else {
          continue
        }
        tightest = Reading(
          provider: item.identity.provider,
          remainingPercent: window.remainingPercent
        )
      }
    }
    return tightest
  }

  /// Which Overview readings still describe live quota, in Overview's order.
  ///
  /// Time enters the item's content in exactly one place — this verdict — because a percent
  /// does not move on its own and only the freshness rule can retire it. A caller that has to
  /// re-evaluate the item on a clock compares this instead of the label, so a minute in which
  /// nothing aged out costs nothing.
  static func currency(of overview: [LocalServiceOverviewItem], now: Date) -> [Bool] {
    overview.map { isCurrent($0, now: now) }
  }

  /// A reading that still describes live quota: the source reported it could read, and the
  /// shared freshness rule has not aged it out.
  private static func isCurrent(_ item: LocalServiceOverviewItem, now: Date) -> Bool {
    !item.isStale && item.snapshot.observedState(now: now) == .available
  }
}
