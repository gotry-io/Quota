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

/// One remaining percent in a cell: a lone number, or one row of a cadence pair.
struct MenuBarLabelLine: Equatable, Hashable, Sendable {
  /// Compact cadence tag (`H`, `W`, `M`) when this row is part of a stacked pair.
  let compactCadence: String?
  let percent: String
  /// What VoiceOver calls this row's cadence. The tag is one letter because the eye reads it
  /// next to its neighbour; a listener has no neighbour to compare it with.
  let spokenCadence: String?

  init(percent: String, compactCadence: String? = nil, spokenCadence: String? = nil) {
    self.percent = percent
    self.compactCadence = compactCadence
    self.spokenCadence = spokenCadence
  }

  var isStacked: Bool { compactCadence != nil }
}

/// One reading in the menu bar: a mark, a remaining percent, or a stacked cadence pair.
struct MenuBarLabelCell: Equatable, Hashable, Sendable {
  let icon: MenuBarLabelIcon?
  let lines: [MenuBarLabelLine]

  /// The lone remaining percent when this cell is a single unlabelled reading.
  var text: String? {
    guard lines.count == 1, !lines[0].isStacked else { return nil }
    return lines[0].percent
  }

  init(icon: MenuBarLabelIcon?, text: String?) {
    self.icon = icon
    self.lines = text.map { [MenuBarLabelLine(percent: $0)] } ?? []
  }

  init(icon: MenuBarLabelIcon?, lines: [MenuBarLabelLine]) {
    self.icon = icon
    self.lines = lines
  }
}

/// The menu-bar item's content: one or more readings composed into a template image.
///
/// The point of an item is that remaining quota is readable without opening anything, so
/// each cell names a single subscription rather than an average or a count. A lone item may
/// stack that subscription's primary cadence pair; a packed item still carries one tightest
/// percent per provider. A reading that no longer describes live quota answers for nothing:
/// a lone item falls back to Quota's mark, and a packed item keeps that provider's mark so
/// the strip does not jump.
struct MenuBarLabelModel: Equatable, Hashable, Sendable {
  let cells: [MenuBarLabelCell]
  let accessibilityLabel: String

  var icon: MenuBarLabelIcon? { cells.count == 1 ? cells.first?.icon : nil }
  var text: String? { cells.count == 1 ? cells.first?.text : nil }

  /// This label's reading, named for the provider it belongs to, for a packed item that has to
  /// say whose number it is. Falls back to the bare name when there is no reading to report.
  fileprivate func spokenReading(of provider: ProviderID) -> String {
    if let text { return "\(provider.displayName) \(text) remaining" }
    guard let lines = cells.first?.lines, !lines.isEmpty else { return provider.displayName }
    let parts = lines.map { line in
      [line.spokenCadence, line.percent, "remaining"].compactMap { $0 }.joined(separator: " ")
    }
    return "\(provider.displayName) \(parts.joined(separator: ", "))"
  }

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
          label: label(
            overview: overview,
            style: style,
            allowed: nil,
            stackCadences: true,
            now: now
          )
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
          label: label(
            overview: overview,
            style: style,
            allowed: id,
            stackCadences: true,
            now: now
          )
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
        stackCadences: true,
        now: now
      )
      cells.append(contentsOf: part.cells)
      // Each part already phrased its own reading; the packed item says whose it is and keeps
      // the rest, so a stacked pair is spoken as a pair here too.
      spoken.append(part.spokenReading(of: id))
    }
    return MenuBarLabelModel(cells: cells, accessibilityLabel: spoken.joined(separator: ", "))
  }

  private static func label(
    overview: [LocalServiceOverviewItem],
    style: MenuBarStylePreference,
    allowed: ProviderID?,
    absentIcon: MenuBarLabelIcon = .quota,
    stackCadences: Bool,
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
    let icon: MenuBarLabelIcon? = style.showsIcon ? .provider(tightest.provider) : nil
    if stackCadences {
      return cadenceLabel(item: tightest.item, icon: icon, fallbackPercent: tightest.remainingPercent)
    }
    let percent = RemainingQuotaFormat.percent(tightest.remainingPercent)
    return MenuBarLabelModel(
      icon: icon,
      text: percent,
      accessibilityLabel: "QuotaBar, \(tightest.provider.displayName) \(percent) remaining"
    )
  }

  /// A lone item's reading: the primary cadence pair when that subscription has one, otherwise
  /// the one primary cadence, otherwise the tightest remaining percent.
  private static func cadenceLabel(
    item: LocalServiceOverviewItem,
    icon: MenuBarLabelIcon?,
    fallbackPercent: Double
  ) -> MenuBarLabelModel {
    let name = item.identity.provider.displayName
    let cadences = item.snapshot.primaryCadenceWindows
    guard cadences.count > 1 else {
      let percent = RemainingQuotaFormat.percent(
        cadences.first?.remainingPercent ?? fallbackPercent
      )
      return MenuBarLabelModel(
        icon: icon,
        text: percent,
        accessibilityLabel: "QuotaBar, \(name) \(percent) remaining"
      )
    }
    // One pass, so the row a reader sees and the phrase VoiceOver speaks cannot disagree
    // about a percent.
    var lines: [MenuBarLabelLine] = []
    var spoken: [String] = []
    for window in cadences.prefix(2) {
      let percent = RemainingQuotaFormat.percent(window.remainingPercent)
      lines.append(
        MenuBarLabelLine(
          percent: percent,
          compactCadence: window.primaryCadenceKind?.compactTag,
          spokenCadence: window.title
        )
      )
      spoken.append("\(window.title) \(percent) remaining")
    }
    return MenuBarLabelModel(
      cells: [MenuBarLabelCell(icon: icon, lines: lines)],
      accessibilityLabel: "QuotaBar, \(name), \(spoken.joined(separator: ", "))"
    )
  }

  private struct Reading {
    let item: LocalServiceOverviewItem
    let remainingPercent: Double

    var provider: ProviderID { item.identity.provider }
  }

  /// The smallest remaining percent any window of any current reading reports, among the
  /// readings `allowed` names — or every current reading when `allowed` is nil.
  ///
  /// Balance-only windows carry no budget to be a percent of, so they cannot be the
  /// constraint; every other window can. The provider this returns is whose cadence pair a
  /// lone item then shows; extras can win the choice without occupying the pair.
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
        tightest = Reading(item: item, remainingPercent: window.remainingPercent)
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
