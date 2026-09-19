import Foundation

/// CSV / JSON for the Usage period already on screen. QuotaBar and the website both answer
/// `packages/protocol/fixtures/usage-export-conformance.json`. See ADR 0056.
enum UsageExport {
  static let csvHeader =
    "date,total tokens,input,output,cache read,cache write,reasoning,messages,"
    + "API-equivalent cost,cost status"
  static let costBasis = "API-equivalent"
  static let noUsageRecorded = "no usage recorded"
  static let hourGridRule =
    "first_whole_hour_of_local_date; fractional_midnight_to_previous_day; no_proration"

  enum Format: String, Sendable {
    case csv
    case json
  }

  enum CellKind: Sendable {
    case text
    case number
  }

  struct Bounds: Equatable, Sendable {
    var start: String
    var end: String
    var grid: String
  }

  struct Coverage: Equatable, Sendable {
    var partial: Bool
    var truncatedByRetention: Bool
  }

  struct Revision: Equatable, Sendable {
    var usageRevision: Int
    var deviceGeneration: Int
    var accountUpdatedAt: String?
    var pricingRevision: String
    var modelCatalogRevision: String
    var foldVersion: Int
  }

  struct DayInput: Equatable, Sendable {
    var date: String
    var totalTokens: Int
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var reasoningTokens: Int
    var messages: Int
    var amountMicrousd: String?
    var costStatus: String
  }

  struct Input: Equatable, Sendable {
    var scope: String
    var from: String
    var to: String
    var timezone: String
    var bounds: Bounds?
    var coverage: Coverage
    var revision: Revision?
    var exportedAt: String
    var appVersion: String
    var days: [DayInput]
  }

  struct DayOutput: Equatable, Sendable {
    var date: String
    var totalTokens: Int
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var reasoningTokens: Int
    var messages: Int
    var apiEquivalentCost: String?
    var costStatus: String
  }

  static func filename(from: String, to: String, format: Format) -> String {
    "quota-usage-\(from)-\(to).\(format.rawValue)"
  }

  static func csvCell(_ value: String, kind: CellKind = .text) -> String {
    if kind == .number { return value }
    var text = value
    if let first = text.unicodeScalars.first, formulaPrefixes.contains(first) {
      text = "'" + text
    }
    if text.contains(where: { $0 == "\"" || $0 == "," || $0 == "\n" || $0 == "\r" }) {
      return "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return text
  }

  static func dollars(microusd: String) -> String {
    var digits = microusd
    if digits.isEmpty { return "0" }
    if digits.count < 7 {
      digits = String(repeating: "0", count: 7 - digits.count) + digits
    }
    let wholeEnd = digits.index(digits.endIndex, offsetBy: -6)
    let wholeRaw = digits[..<wholeEnd]
    var frac = String(digits[wholeEnd...])
    while frac.last == "0" { frac.removeLast() }
    let whole = wholeRaw.drop { $0 == "0" }
    let wholeText = whole.isEmpty ? "0" : String(whole)
    if frac.isEmpty { return wholeText }
    return "\(wholeText).\(frac)"
  }

  static func costStatus(_ status: String) -> String {
    status == "complete" || status == "partial" ? status : "unpriced"
  }

  static func csv(from input: Input) -> String {
    let byDate = Dictionary(uniqueKeysWithValues: input.days.map { ($0.date, outputDay($0)) })
    var lines = [csvHeader]
    var date = input.from
    while date <= input.to {
      if let day = byDate[date] {
        lines.append(csvRow(day))
      } else {
        lines.append(
          [csvCell(date), "", "", "", "", "", "", "", "", csvCell(noUsageRecorded)].joined(
            separator: ","))
      }
      date = nextDate(date)
    }
    return lines.joined(separator: "\n") + "\n"
  }

  static func jsonObject(from input: Input) -> [String: Any] {
    var object: [String: Any] = [
      "scope": input.scope,
      "from": input.from,
      "to": input.to,
      "timezone": input.timezone,
      "cost_basis": costBasis,
      "coverage": [
        "partial": input.coverage.partial,
        "truncated_by_retention": input.coverage.truncatedByRetention,
      ],
      "exported_at": input.exportedAt,
      "app_version": input.appVersion,
      "days": input.days.map(jsonDay),
    ]
    if let bounds = input.bounds {
      object["bounds"] = ["start": bounds.start, "end": bounds.end, "grid": bounds.grid]
    } else {
      object["bounds"] = NSNull()
    }
    if let revision = input.revision {
      object["revision"] = [
        "usage_revision": revision.usageRevision,
        "device_generation": revision.deviceGeneration,
        "account_updated_at": (revision.accountUpdatedAt as Any?) ?? NSNull(),
        "pricing_revision": revision.pricingRevision,
        "model_catalog_revision": revision.modelCatalogRevision,
        "fold_version": revision.foldVersion,
      ]
    } else {
      object["revision"] = NSNull()
    }
    return object
  }

  static func jsonText(from input: Input) throws -> String {
    let data = try JSONSerialization.data(
      withJSONObject: jsonObject(from: input),
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    return String(decoding: data, as: UTF8.self) + "\n"
  }

  static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  /// The period already on screen. `days` omitted means this is not a daily export.
  static func input(
    detail: LocalServiceUsageDetail,
    scope: String,
    range: (from: String, to: String),
    timezone: String,
    exportedAt: String,
    appVersion: String
  ) -> Input? {
    guard let days = detail.usage.days else { return nil }
    return Input(
      scope: scope,
      from: range.from,
      to: range.to,
      timezone: timezone,
      bounds: detail.bounds.map {
        Bounds(start: $0.start, end: $0.end, grid: $0.grid)
      },
      coverage: Coverage(
        partial: detail.coverage?.partial ?? detail.incomplete,
        truncatedByRetention: detail.coverage?.truncatedByRetention ?? false
      ),
      revision: detail.revision.map {
        Revision(
          usageRevision: $0.usageRevision,
          deviceGeneration: $0.deviceGeneration,
          accountUpdatedAt: $0.accountUpdatedAt,
          pricingRevision: $0.pricingRevision,
          modelCatalogRevision: $0.modelCatalogRevision,
          foldVersion: $0.foldVersion
        )
      },
      exportedAt: exportedAt,
      appVersion: appVersion,
      days: days.map {
        DayInput(
          date: $0.date,
          totalTokens: $0.totals.totalTokens,
          inputTokens: $0.totals.inputTokens,
          outputTokens: $0.totals.outputTokens,
          cacheReadTokens: $0.totals.cacheReadInputTokens,
          cacheWriteTokens: $0.totals.cacheWriteInputTokens,
          reasoningTokens: $0.totals.reasoningTokens,
          messages: $0.totals.messages,
          amountMicrousd: $0.cost.amountMicrousd,
          costStatus: $0.cost.status.rawValue
        )
      }
    )
  }

  private static let formulaPrefixes: Set<Unicode.Scalar> = [
    "=", "+", "-", "@", "\t", "\r",
  ]

  private static func outputDay(_ day: DayInput) -> DayOutput {
    let status = costStatus(day.costStatus)
    let cost: String?
    if status == "unpriced" || day.amountMicrousd == nil {
      cost = nil
    } else if let amount = day.amountMicrousd {
      cost = dollars(microusd: amount)
    } else {
      cost = nil
    }
    return DayOutput(
      date: day.date,
      totalTokens: day.totalTokens,
      inputTokens: day.inputTokens,
      outputTokens: day.outputTokens,
      cacheReadTokens: day.cacheReadTokens,
      cacheWriteTokens: day.cacheWriteTokens,
      reasoningTokens: day.reasoningTokens,
      messages: day.messages,
      apiEquivalentCost: cost,
      costStatus: status
    )
  }

  private static func csvRow(_ day: DayOutput) -> String {
    [
      csvCell(day.date),
      csvCell(String(day.totalTokens), kind: .number),
      csvCell(String(day.inputTokens), kind: .number),
      csvCell(String(day.outputTokens), kind: .number),
      csvCell(String(day.cacheReadTokens), kind: .number),
      csvCell(String(day.cacheWriteTokens), kind: .number),
      csvCell(String(day.reasoningTokens), kind: .number),
      csvCell(String(day.messages), kind: .number),
      day.apiEquivalentCost.map { csvCell($0, kind: .number) } ?? "",
      csvCell(day.costStatus),
    ].joined(separator: ",")
  }

  private static func jsonDay(_ day: DayInput) -> [String: Any] {
    let output = outputDay(day)
    return [
      "date": output.date,
      "total_tokens": output.totalTokens,
      "input_tokens": output.inputTokens,
      "output_tokens": output.outputTokens,
      "cache_read_tokens": output.cacheReadTokens,
      "cache_write_tokens": output.cacheWriteTokens,
      "reasoning_tokens": output.reasoningTokens,
      "messages": output.messages,
      "api_equivalent_cost": (output.apiEquivalentCost as Any?) ?? NSNull(),
      "cost_status": output.costStatus,
    ]
  }

  private static func nextDate(_ date: String) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    guard let parsed = formatter.date(from: date),
      let next = calendar.date(byAdding: .day, value: 1, to: parsed)
    else { return date }
    return formatter.string(from: next)
  }
}
