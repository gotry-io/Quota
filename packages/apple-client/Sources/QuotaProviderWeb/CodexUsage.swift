import Foundation
import QuotaWire

/// Codex's usage document, read the way the Rust collector reads it.
enum CodexUsage {
  struct Mapped {
    var plan: String?
    var email: String?
    var accountID: String?
    var windows: [QuotaWindow] = []
    /// A 200 whose headline slots are there and unreadable. It is a failure to map, not an
    /// account with nothing to report, so it is never reported as a reading.
    var malformedSuccess = false
  }

  static let fiveHourSeconds = 18_000
  static let weeklySeconds = 604_800
  static let monthlySeconds = 2_592_000

  static func map(_ value: JSONValue) -> Mapped {
    guard value.isObject else { return Mapped(plan: nil, email: nil, accountID: nil, malformedSuccess: true) }
    var mapped = Mapped(
      plan: ProviderJSON.string(value.get(any: ["plan_type", "planType"])),
      email: ProviderJSON.string(value.get("email")),
      accountID: ProviderJSON.string(value.get(any: ["account_id", "accountId"]))
    )
    let rateLimit = value.get(any: ["rate_limit", "rateLimit"])
    let primarySlot = rateLimit?.get(any: ["primary_window", "primaryWindow"])
    let secondarySlot = rateLimit?.get(any: ["secondary_window", "secondaryWindow"])
    // `normalize` relabels both from the duration, so these are read as "the primary slot" and
    // "the secondary slot", not as the cadence they end up naming.
    let primary = primarySlot.flatMap { window($0, id: "primary", title: "Primary") }
    let secondary = secondarySlot.flatMap { window($0, id: "secondary", title: "Secondary") }
    var windows = normalize(primary: primary, secondary: secondary)
    windows.append(
      contentsOf: additional(value.get(any: ["additional_rate_limits", "additionalRateLimits"])))
    windows.append(
      contentsOf: codeReview(value.get(any: ["code_review_rate_limit", "codeReviewRateLimit"])))
    let malformedPrimary = (primarySlot.map { !$0.isNull } ?? false) && primary == nil
    let malformedSecondary = (secondarySlot.map { !$0.isNull } ?? false) && secondary == nil
    mapped.malformedSuccess =
      windows.isEmpty && (malformedPrimary || malformedSecondary)
    mapped.windows = windows
    return mapped
  }

  /// A window whose reported duration names no known cadence keeps the cadence of the payload
  /// slot it arrived in.
  static func classify(_ duration: Int?, fallback: Cadence) -> Cadence {
    switch duration {
    case fiveHourSeconds: .fiveHour
    case weeklySeconds: .weekly
    case monthlySeconds: .monthly
    default: fallback
    }
  }

  static func window(_ value: JSONValue, id: String, title: String) -> QuotaWindow? {
    guard let used = ProviderJSON.number(value.get(any: ["used_percent", "usedPercent"]))
    else { return nil }
    return QuotaWindow.make(
      id: id,
      title: title,
      usedPercent: used,
      resetsAt: ProviderJSON.date(
        value.get(any: ["reset_at", "resetAt", "resetsAt", "resets_at"])),
      durationSeconds: durationSeconds(value)
    )
  }

  static func durationSeconds(_ value: JSONValue) -> Int? {
    if let seconds = ProviderJSON.number(
      value.get(any: ["limit_window_seconds", "limitWindowSeconds"])), seconds >= 0
    {
      return Int(seconds.rounded(.down))
    }
    guard
      let minutes = ProviderJSON.number(
        value.get(
          any: [
            "windowDurationMins", "window_duration_mins", "windowMinutes", "window_minutes",
          ])), minutes >= 0
    else { return nil }
    return Int((minutes * 60).rounded(.down))
  }

  private static func normalize(primary: QuotaWindow?, secondary: QuotaWindow?) -> [QuotaWindow] {
    var labeled: [(Cadence, QuotaWindow)] = []
    if let primary { labeled.append(label(primary, fallback: .fiveHour)) }
    if let secondary {
      let entry = label(secondary, fallback: .weekly)
      if !labeled.contains(where: { $0.0 == entry.0 }) { labeled.append(entry) }
    }
    return labeled.sorted { $0.0 < $1.0 }.map(\.1)
  }

  /// Codex's headline windows are ided by their cadence, so one value answers for the id, the
  /// title, and the member a client trusts.
  private static func label(_ window: QuotaWindow, fallback: Cadence) -> (Cadence, QuotaWindow) {
    let cadence = classify(window.durationSeconds, fallback: fallback)
    return (
      cadence,
      QuotaWindow(
        id: cadence.wire,
        title: cadence.title,
        usedPercent: window.usedPercent,
        resetsAt: window.resetsAt,
        durationSeconds: window.durationSeconds,
        primaryCadence: cadence.primaryCadence
      )
    )
  }

  private static func additional(_ value: JSONValue?) -> [QuotaWindow] {
    guard let entries = value?.arrayValue else { return [] }
    var used = Set<String>()
    var windows: [QuotaWindow] = []
    for entry in entries {
      let limitName = ProviderJSON.string(entry.get(any: ["limit_name", "limitName"]))
      let metered = ProviderJSON.string(entry.get(any: ["metered_feature", "meteredFeature"]))
      let rate = entry.get(any: ["rate_limit", "rateLimit"])
      let primary = rate?.get(any: ["primary_window", "primaryWindow"])
      let secondary = rate?.get(any: ["secondary_window", "secondaryWindow"])
      let spark = [limitName, metered].compactMap { $0 }
        .contains { $0.lowercased().contains("spark") }
      if spark {
        windows.append(
          contentsOf: named(
            primary: primary, secondary: secondary,
            fiveID: "codex-spark", fiveTitle: "Codex Spark 5 Hours",
            weeklyID: "codex-spark-weekly", weeklyTitle: "Codex Spark Weekly",
            used: &used))
        continue
      }
      guard let source = metered ?? limitName else { continue }
      let id = "codex-\(ProviderJSON.slug(source, separator: "-"))"
      if used.contains(id) { continue }
      guard let slot = primary ?? secondary,
        let window = self.window(
          slot, id: id,
          title: ProviderJSON.displayWindowTitle(limitName ?? metered ?? "Codex extra limit"))
      else { continue }
      used.insert(id)
      windows.append(window)
    }
    return windows
  }

  private static func codeReview(_ value: JSONValue?) -> [QuotaWindow] {
    guard let value, value.isObject else { return [] }
    var used = Set<String>()
    return named(
      primary: value.get(any: ["primary_window", "primaryWindow"]),
      secondary: value.get(any: ["secondary_window", "secondaryWindow"]),
      fiveID: "codex-code-review", fiveTitle: "Code Review 5 Hours",
      weeklyID: "codex-code-review-weekly", weeklyTitle: "Code Review Weekly",
      used: &used)
  }

  private static func named(
    primary: JSONValue?,
    secondary: JSONValue?,
    fiveID: String,
    fiveTitle: String,
    weeklyID: String,
    weeklyTitle: String,
    used: inout Set<String>
  ) -> [QuotaWindow] {
    var windows: [QuotaWindow] = []
    for (candidate, fallback) in [(primary, Cadence.fiveHour), (secondary, Cadence.weekly)] {
      guard let candidate else { continue }
      let (id, title) =
        switch classify(durationSeconds(candidate), fallback: fallback) {
        case .fiveHour: (fiveID, fiveTitle)
        case .weekly, .monthly: (weeklyID, weeklyTitle)
        }
      guard let window = window(candidate, id: id, title: title) else { continue }
      if used.insert(id).inserted { windows.append(window) }
    }
    return windows
  }
}
