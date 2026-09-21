import Foundation
import QuotaPresentation

/// The Account settings document: the alert policy, the monthly budget, and the history switch
/// every signed-in client of one Account shares. The rule is
/// [ADR 0061](../../../../docs/decisions/0061-alert-policy-and-the-budget-follow-the-account.md)
/// and [ADR 0062](../../../../docs/decisions/0062-quota-history-may-follow-the-account.md).
///
/// Decoding takes what `GET /api/v2/account/settings` answered, or the stored shape a write
/// carries, and ignores a key this build does not name. A document without `history` is
/// `sync: false` (a Relay that predates the field). Encoding writes the update request `PUT`
/// takes — `protocol_version`, `alerts`, `budget`, and `history` only when this write names it
/// — because `revision` and `updated_at` are Relay's to assign, so what comes out is
/// deliberately not what went in (ADR 0023). Absent `history` on the wire means unchanged.
///
/// The keys are the wire's own `snake_case`, spelled here rather than derived, so this type must
/// be decoded by a coder that converts no keys: `decode(_:)`, `storedJSON()`, and
/// `updateRequestJSON()` are that coder. `enabled` is not in the document. It is the per-device
/// notification permission, and a shared copy would let one denied device silence every other.
public struct AccountSettingsDocument: Codable, Equatable, Sendable {
  /// The revision a write states in `If-Match`. Zero is an Account nothing has been written to,
  /// which is also what the stored shape — carrying no revision of its own — reads as.
  public var revision: Int
  /// When Relay last wrote the document. The stored shape does not carry it, and a synthesized
  /// revision-zero answer says `1970-01-01T00:00:00Z` because nothing has been written.
  public var updatedAt: Date?
  public var alerts: Alerts
  public var budget: Budget
  public var history: History
  /// Whether a PUT names `history`. A read, and a write that does not edit the switch, leave
  /// this false so the body omits the field (absent = unchanged).
  public var writesHistory: Bool
  /// Whether the stored JSON named `history`. Normalize always stores the field; a 412 reapply
  /// only emits it when the fresh document had it.
  public var historyPresent: Bool

  public init(
    revision: Int = 0,
    updatedAt: Date? = nil,
    alerts: Alerts,
    budget: Budget,
    history: History = History(sync: false),
    writesHistory: Bool = false,
    historyPresent: Bool = false
  ) {
    self.revision = revision
    self.updatedAt = updatedAt
    self.alerts = alerts
    self.budget = budget
    self.history = history
    self.writesHistory = writesHistory
    self.historyPresent = historyPresent
  }

  /// Whether remaining-quota history follows the Account.
  public struct History: Codable, Equatable, Sendable {
    public var sync: Bool

    public init(sync: Bool) {
      self.sync = sync
    }
  }

  /// The alert policy the Account owns: the two switches and the thresholds map.
  public struct Alerts: Codable, Equatable, Sendable {
    public var resetReminders: Bool
    /// Warn once when a window's burn rate stops lasting to its reset.
    public var paceAlerts: Bool
    /// Remaining-percent thresholds by subscription selector: one or two integers in 1…99,
    /// strictly descending. A selector the map does not name uses `AlertRules.defaultThresholds`.
    public var thresholds: [String: [Int]]

    public init(resetReminders: Bool, paceAlerts: Bool, thresholds: [String: [Int]]) {
      self.resetReminders = resetReminders
      self.paceAlerts = paceAlerts
      self.thresholds = thresholds
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      resetReminders = try container.decode(Bool.self, forKey: .resetReminders)
      paceAlerts = try container.decode(Bool.self, forKey: .paceAlerts)
      let thresholds = try container.decode([String: [Int]].self, forKey: .thresholds)
      guard thresholds.count <= AccountSettings.maximumSelectors else {
        throw DecodingError.dataCorruptedError(
          forKey: .thresholds,
          in: container,
          debugDescription: "At most \(AccountSettings.maximumSelectors) selectors."
        )
      }
      for (selector, values) in thresholds {
        guard AccountSettingsDocument.isSelector(selector) else {
          throw DecodingError.dataCorruptedError(
            forKey: .thresholds,
            in: container,
            debugDescription: "A selector is twelve lowercase hex characters."
          )
        }
        guard AccountSettingsDocument.isThresholdList(values) else {
          throw DecodingError.dataCorruptedError(
            forKey: .thresholds,
            in: container,
            debugDescription: "Thresholds are one or two integers in 1…99, strictly descending."
          )
        }
      }
      self.thresholds = thresholds
    }

    enum CodingKeys: String, CodingKey {
      case resetReminders = "reset_reminders"
      case paceAlerts = "pace_alerts"
      case thresholds
    }
  }

  /// The monthly API-equivalent spend budget the Account owns.
  public struct Budget: Codable, Equatable, Sendable {
    /// Nil is no budget. The wire carries a decimal string so three runtimes agree on the cents;
    /// nothing on this path goes through a `Double`.
    public var amountUSD: Decimal?
    /// Whether crossing a share of the amount posts a notification.
    public var alerts: Bool

    /// An amount outside `(0, UsageBudget.maximumAmountUSD]` is no budget at all, which is what
    /// `UsageBudget` already says about the same number.
    public init(amountUSD: Decimal?, alerts: Bool) {
      self.amountUSD = UsageBudget.normalized(amountUSD)
      self.alerts = alerts
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if let raw = try container.decode(String?.self, forKey: .amountUSD) {
        guard let amount = AccountSettingsDocument.budgetAmount(wire: raw) else {
          throw DecodingError.dataCorruptedError(
            forKey: .amountUSD,
            in: container,
            debugDescription: "A budget is a decimal string in (0, 1000000] with at most two "
              + "fraction digits."
          )
        }
        amountUSD = amount
      } else {
        amountUSD = nil
      }
      alerts = try container.decode(Bool.self, forKey: .alerts)
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      if let amountUSD {
        try container.encode(AccountSettingsDocument.wireAmount(amountUSD), forKey: .amountUSD)
      } else {
        try container.encodeNil(forKey: .amountUSD)
      }
      try container.encode(alerts, forKey: .alerts)
    }

    enum CodingKeys: String, CodingKey {
      case amountUSD = "amount_usd"
      case alerts
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    if let raw = try container.decodeIfPresent(String.self, forKey: .updatedAt) {
      guard let instant = Self.instant(wire: raw) else {
        throw DecodingError.dataCorruptedError(
          forKey: .updatedAt,
          in: container,
          debugDescription: "Expected an RFC 3339 instant."
        )
      }
      updatedAt = instant
    } else {
      updatedAt = nil
    }
    alerts = try container.decode(Alerts.self, forKey: .alerts)
    budget = try container.decode(Budget.self, forKey: .budget)
    historyPresent = container.contains(.history)
    history = try container.decodeIfPresent(History.self, forKey: .history) ?? History(sync: false)
    writesHistory = false
  }

  /// The update request, which is the only shape a client may write.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(QuotaProtocol.control, forKey: .protocolVersion)
    try container.encode(alerts, forKey: .alerts)
    try container.encode(budget, forKey: .budget)
    if writesHistory {
      try container.encode(history, forKey: .history)
    }
  }

  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
    case revision
    case updatedAt = "updated_at"
    case alerts
    case budget
    case history
  }

  /// The document a `GET` — or a 412 — answered.
  public static func decode(_ json: Data) throws -> AccountSettingsDocument {
    try JSONDecoder().decode(AccountSettingsDocument.self, from: json)
  }

  /// The body of a `PUT`: `protocol_version`, `alerts`, and `budget`, and `history` only when
  /// this write names the switch.
  public func updateRequestJSON() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  /// The stored policy: `alerts`, `budget`, and `history`. Not a PUT body.
  public func storedJSON() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(StoredShape(self))
  }
}

/// The stored document as the fixture compares it: policy only, `history` when the document
/// named it (or after normalize, which always stores the field).
private struct StoredShape: Encodable {
  var alerts: AccountSettingsDocument.Alerts
  var budget: AccountSettingsDocument.Budget
  var history: AccountSettingsDocument.History
  var historyPresent: Bool

  init(_ document: AccountSettingsDocument) {
    alerts = document.alerts
    budget = document.budget
    history = document.history
    historyPresent = document.historyPresent
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(alerts, forKey: .alerts)
    try container.encode(budget, forKey: .budget)
    if historyPresent {
      try container.encode(history, forKey: .history)
    }
  }

  enum CodingKeys: String, CodingKey {
    case alerts
    case budget
    case history
  }
}

extension AccountSettingsDocument {
  /// Whether the JSON names only the keys the stored document defines, at every level. A read
  /// ignores a key it does not know; a write carrying one is refused (ADR 0023).
  static func namesOnlyStoredKeys(_ json: Data) -> Bool {
    (try? JSONDecoder().decode(StoredKeys.self, from: json)) != nil
  }

  /// A selector is `SHA-256(provider|fingerprint|scope|source_id)[0:12]`, so twelve lowercase hex
  /// characters and never anything else.
  static func isSelector(_ selector: String) -> Bool {
    selector.count == 12 && selector.allSatisfy(hexDigits.contains)
  }

  /// One or two remaining-percent integers in 1…99, strictly descending.
  static func isThresholdList(_ values: [Int]) -> Bool {
    guard (1...AccountSettings.maximumThresholds).contains(values.count),
      values.allSatisfy({ (1...99).contains($0) })
    else { return false }
    return zip(values, values.dropFirst()).allSatisfy { $0 > $1 }
  }

  /// The amount a wire string names, or nil when it is not `\d{1,7}(\.\d{1,2})?` in
  /// `(0, UsageBudget.maximumAmountUSD]`. Read as a decimal, never through a `Double`.
  static func budgetAmount(wire: String) -> Decimal? {
    let parts = wire.split(separator: ".", omittingEmptySubsequences: false)
    guard let whole = parts.first, (1...7).contains(whole.count),
      whole.allSatisfy(digits.contains), parts.count <= 2
    else { return nil }
    if parts.count == 2 {
      let fraction = parts[1]
      guard (1...2).contains(fraction.count), fraction.allSatisfy(digits.contains) else {
        return nil
      }
    }
    guard let amount = Decimal(string: wire, locale: Locale(identifier: "en_US_POSIX")),
      amount > 0, amount <= UsageBudget.maximumAmountUSD
    else { return nil }
    return amount
  }

  /// An amount as the wire carries it: cents, as a decimal string with two fraction digits. A
  /// `Decimal` keeps no trailing zero of its own, so the cents are written here rather than
  /// recovered from however the amount was typed.
  static func wireAmount(_ amount: Decimal) -> String {
    var scaled = amount * 100
    var rounded = Decimal()
    NSDecimalRound(&rounded, &scaled, 0, .plain)
    let cents = NSDecimalNumber(decimal: rounded).intValue
    let fraction = cents % 100
    return "\(cents / 100).\(fraction < 10 ? "0" : "")\(fraction)"
  }

  /// The instant an RFC 3339 field names, with or without fractional seconds: Relay writes them
  /// and a synthesized document says `1970-01-01T00:00:00Z`.
  static func instant(wire: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let instant = fractional.date(from: wire) { return instant }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: wire)
  }

  private static let digits = Set("0123456789")
  private static let hexDigits = Set("0123456789abcdef")
}

/// Refuses a document naming a key the stored shape does not define, and decodes nothing else.
private struct StoredKeys: Decodable {
  init(from decoder: any Decoder) throws {
    let root = try decoder.container(keyedBy: WireKey.self)
    try Self.refuseUnknown(in: root, allowed: ["alerts", "budget", "history"])
    try Self.refuseUnknown(
      in: try root.nestedContainer(keyedBy: WireKey.self, forKey: WireKey("alerts")),
      allowed: ["reset_reminders", "pace_alerts", "thresholds"]
    )
    try Self.refuseUnknown(
      in: try root.nestedContainer(keyedBy: WireKey.self, forKey: WireKey("budget")),
      allowed: ["amount_usd", "alerts"]
    )
    if root.contains(WireKey("history")) {
      try Self.refuseUnknown(
        in: try root.nestedContainer(keyedBy: WireKey.self, forKey: WireKey("history")),
        allowed: ["sync"]
      )
    }
  }

  private static func refuseUnknown(
    in container: KeyedDecodingContainer<WireKey>,
    allowed: Set<String>
  ) throws {
    for key in container.allKeys where !allowed.contains(key.stringValue) {
      throw DecodingError.dataCorruptedError(
        forKey: key,
        in: container,
        debugDescription: "A write states only the keys this document defines."
      )
    }
  }
}

/// Any key, so a strict check can see the ones the document does not define.
private struct WireKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }

  init(_ stringValue: String) {
    self.stringValue = stringValue
  }

  init?(stringValue: String) {
    self.init(stringValue)
  }

  init?(intValue: Int) {
    nil
  }
}
