import Foundation
import QuotaWire

/// Claude's usage document, read the way the Rust collector reads it.
enum ClaudeUsage {
  /// One of Claude's fixed usage windows, named once so the document's key, the window id this
  /// build reports, and its title cannot drift apart.
  struct Window {
    let field: String
    let id: String
    let title: String
    let durationSeconds: Int
    /// Weekly-group limits meter one seven-day cycle and therefore share its reset. Claude's
    /// other seven-day-long limits, such as Routines, are not in that group.
    let weeklyGroup: Bool
    let primaryCadence: Cadence?
  }

  static let weekSeconds = 604_800
  static let scopedWeeklyPrefix = "claude-weekly-scoped-"

  static let windows: [Window] = [
    Window(
      field: "five_hour", id: "five_hour", title: Cadence.fiveHour.title,
      durationSeconds: 18_000, weeklyGroup: false, primaryCadence: .fiveHour),
    Window(
      field: "seven_day", id: "seven_day", title: Cadence.weekly.title,
      durationSeconds: 604_800, weeklyGroup: true, primaryCadence: .weekly),
    Window(
      field: "seven_day_sonnet", id: "seven_day_sonnet", title: "Sonnet Weekly",
      durationSeconds: 604_800, weeklyGroup: true, primaryCadence: nil),
    Window(
      field: "seven_day_opus", id: "seven_day_opus", title: "Opus Weekly",
      durationSeconds: 604_800, weeklyGroup: true, primaryCadence: nil),
    Window(
      field: "seven_day_oauth_apps", id: "seven_day_oauth_apps", title: "OAuth Apps Weekly",
      durationSeconds: 604_800, weeklyGroup: true, primaryCadence: nil),
  ]

  /// Whether the response named a window this build knows and answered `null` for it, which is an
  /// account stating it has no such window rather than a shape this build failed to read.
  static func answersForAKnownWindow(_ value: JSONValue) -> Bool {
    windows.contains { value.get($0.field)?.isNull == true }
  }

  static func map(_ value: JSONValue) -> [QuotaWindow] {
    var mapped: [QuotaWindow] = []
    var weeklyGroup: [String] = []
    for entry in windows {
      guard
        let window = usageWindow(
          value.get(entry.field), id: entry.id, title: entry.title,
          duration: entry.durationSeconds, primaryCadence: entry.primaryCadence)
      else { continue }
      if entry.weeklyGroup { weeklyGroup.append(window.id) }
      mapped.append(window)
    }
    // `limits[]` reports only `weekly_scoped` entries of the `weekly` group.
    if let limits = value.get("limits")?.arrayValue {
      var seen = Set<String>()
      for entry in limits {
        guard ProviderJSON.string(entry.get("kind")) == "weekly_scoped",
          ProviderJSON.string(entry.get("group")) == "weekly",
          let percent = ProviderJSON.number(entry.get("percent"))
        else { continue }
        let model = entry.get("scope")?.get("model")
        guard
          let modelName = model.flatMap({
            ProviderJSON.string($0.get(any: ["display_name", "displayName"]))
          })
        else { continue }
        let modelID = model.flatMap { ProviderJSON.string($0.get("id")) }
        if isAllModels(modelID: modelID, modelName: modelName) { continue }
        let identity = modelID ?? modelName
        let id = "\(scopedWeeklyPrefix)\(ProviderJSON.slug(identity, separator: "-"))"
        guard seen.insert(id).inserted else { continue }
        weeklyGroup.append(id)
        mapped.append(
          QuotaWindow.make(
            id: id,
            title: "\(modelName) Only",
            usedPercent: percent,
            resetsAt: ProviderJSON.date(entry.get(any: ["resets_at", "resetsAt"])),
            durationSeconds: weekSeconds
          ))
      }
    }
    let routines = [
      "seven_day_routines", "seven_day_claude_routines", "claude_routines", "routines",
      "routine", "seven_day_cowork", "cowork",
    ].lazy.compactMap { value.get($0) }.first
    if let window = usageWindow(
      routines, id: "claude-routines", title: "Daily Routines", duration: weekSeconds,
      primaryCadence: nil)
    {
      mapped.append(window)
    }
    let extra = value.get("extra_usage") ?? value.get("extraUsage")
    if let utilization = extra.flatMap({ ProviderJSON.number($0.get("utilization")) }) {
      mapped.append(
        QuotaWindow.make(id: "extra_usage", title: "Extra Usage", usedPercent: utilization))
    }
    return inheritWeeklyReset(mapped, group: weeklyGroup)
  }

  static func usageWindow(
    _ value: JSONValue?,
    id: String,
    title: String,
    duration: Int,
    primaryCadence: Cadence?
  ) -> QuotaWindow? {
    guard let value,
      let utilization = ProviderJSON.number(
        value.get(any: ["utilization", "utilization_pct", "percent"]))
    else { return nil }
    return QuotaWindow(
      id: id,
      title: title,
      usedPercent: ProviderJSON.clampPercent(utilization),
      resetsAt: ProviderJSON.date(
        value.get(any: ["resets_at", "resetsAt", "reset_at", "resetAt"])
      ).map { Date(timeIntervalSince1970: Double($0)) },
      durationSeconds: duration,
      primaryCadence: primaryCadence?.primaryCadence
    )
  }

  /// Every weekly limit meters the same seven-day cycle, so a weekly window that reports no reset
  /// of its own resets with `seven_day`. Membership is a Claude limit group, not a duration:
  /// Routines also spans seven days and does not share the weekly reset.
  static func inheritWeeklyReset(_ windows: [QuotaWindow], group: [String]) -> [QuotaWindow] {
    guard let weekly = windows.first(where: { $0.id == "seven_day" })?.resetsAt else {
      return windows
    }
    return windows.map { window in
      guard window.resetsAt == nil, group.contains(window.id) else { return window }
      return QuotaWindow(
        id: window.id,
        title: window.title,
        usedPercent: window.usedPercent,
        resetsAt: weekly,
        durationSeconds: window.durationSeconds,
        primaryCadence: window.primaryCadence
      )
    }
  }

  static func isAllModels(modelID: String?, modelName: String) -> Bool {
    if ProviderJSON.slug(modelName, separator: "-") == "all-models" { return true }
    guard let modelID else { return false }
    let id = ProviderJSON.slug(modelID, separator: "-")
    return id == "all-models" || id.hasSuffix("-all-models")
  }

  /// Claude tiers arrive namespaced (`default_claude_max_5x`); the namespace is Claude's, not a
  /// plan, so it is stripped before the shared slug reaches a client's plan table.
  static func plan(subscriptionType: String?, rateLimitTier: String?) -> String? {
    planSlug(rateLimitTier) ?? planSlug(subscriptionType)
  }

  private static func planSlug(_ raw: String?) -> String? {
    guard let slug = ProviderJSON.planSlug(raw) else { return nil }
    var stripped = slug
    if stripped.hasPrefix("default_") { stripped.removeFirst("default_".count) }
    if stripped.hasPrefix("claude_") { stripped.removeFirst("claude_".count) }
    return stripped.isEmpty ? nil : stripped
  }
}
