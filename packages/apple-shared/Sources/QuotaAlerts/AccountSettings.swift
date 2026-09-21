import Foundation
import QuotaPresentation

/// What a device decides about the Account settings document: whether a write is the document at
/// all, what happens the first time it holds both its own values and the Account's, and how one
/// local edit is replayed onto the document a 412 answered (ADR 0061).
///
/// Every function here is pure. The effective values stay in each app's own `UserDefaults`, so a
/// store asks these what to persist and then persists it. `packages/quota-model` answers
/// `packages/protocol/fixtures/account-settings-conformance.json` with the same three functions,
/// case for case.
public enum AccountSettings: Sendable {
  /// A document names at most this many selectors, which bounds one Account's map.
  public static let maximumSelectors = 256
  /// A selector carries at most this many remaining-percent thresholds, largest first, which is
  /// what both alert editors write.
  public static let maximumThresholds = 2

  /// The stored document, or a refusal when the JSON is not exactly that.
  ///
  /// This is the strict half of ADR 0023: a key this document does not define is refused here,
  /// where a read of Relay's answer ignores it. The stored shape is the policy alone — the
  /// `protocol_version` a request states, `revision`, and `updated_at` all sit around it — so the
  /// document comes back at `revision` zero.
  public static func normalize(_ json: Data) -> AccountSettingsNormalization {
    guard AccountSettingsDocument.namesOnlyStoredKeys(json),
      let document = try? AccountSettingsDocument.decode(json)
    else { return .refused }
    return .ok(document)
  }

  /// What a device does the first time it holds local policy and an Account document.
  ///
  /// Revision zero is an Account with no row: values of this device's own seed it, and the
  /// defaults write nothing. A row wins for every policy field, and the local thresholds for
  /// selectors the Account does not name are merged into it once.
  public static func planFirstSync(
    local: AccountSettingsPolicy,
    account: AccountSettingsDocument
  ) -> AccountSettingsFirstSync {
    if account.revision == 0 {
      if local.isDefault { return .adopt(policy: local) }
      return .seed(write: AccountSettingsDocument(policy: local, revision: account.revision))
    }
    var thresholds = account.alerts.thresholds
    var merged = false
    for (selector, values) in local.thresholds where thresholds[selector] == nil {
      thresholds[selector] = values
      merged = true
    }
    let adopted = AccountSettingsPolicy(
      resetReminders: account.alerts.resetReminders,
      paceAlerts: account.alerts.paceAlerts,
      thresholds: thresholds,
      budgetAmountUSD: account.budget.amountUSD,
      budgetAlerts: account.budget.alerts
    )
    guard merged else { return .adopt(policy: adopted) }
    return .adoptAndMerge(
      policy: adopted,
      write: AccountSettingsDocument(policy: adopted, revision: account.revision)
    )
  }

  /// One local edit replayed onto the document a 412 answered, for the single retry.
  ///
  /// Every other field of the fresh document is carried through, including selectors this build
  /// has never seen: a phone that knows one subscription must not erase a Mac's five.
  public static func reapply(
    edit: AccountSettingsEdit,
    onto fresh: AccountSettingsDocument
  ) -> AccountSettingsDocument {
    var next = fresh
    switch edit {
    case .setResetReminders(let value):
      next.alerts.resetReminders = value
    case .setPaceAlerts(let value):
      next.alerts.paceAlerts = value
    case .setThresholds(let selector, let values):
      next.alerts.thresholds[selector] = wireThresholds(values)
    case .setBudget(let amount, let alerts):
      next.budget = AccountSettingsDocument.Budget(amountUSD: amount, alerts: alerts)
    }
    return next
  }

  /// A local threshold list as the document carries it: normalized the way `AlertRules` normalizes
  /// what it persists, then the largest two, which is all the wire takes.
  static func wireThresholds(_ values: [Int]) -> [Int] {
    Array(AlertRules.normalized(values).prefix(maximumThresholds))
  }
}

/// What `normalize` answered.
public enum AccountSettingsNormalization: Equatable, Sendable {
  case ok(AccountSettingsDocument)
  case refused
}

/// The policy fields the Account owns, as a device holds them. `enabled` is not among them: it is
/// this device's notification permission, which both apps force off when the system denies them.
public struct AccountSettingsPolicy: Equatable, Sendable {
  public var resetReminders: Bool
  public var paceAlerts: Bool
  public var thresholds: [String: [Int]]
  public var budgetAmountUSD: Decimal?
  public var budgetAlerts: Bool

  public init(
    resetReminders: Bool,
    paceAlerts: Bool,
    thresholds: [String: [Int]],
    budgetAmountUSD: Decimal?,
    budgetAlerts: Bool
  ) {
    self.resetReminders = resetReminders
    self.paceAlerts = paceAlerts
    self.thresholds = thresholds
    self.budgetAmountUSD = budgetAmountUSD
    self.budgetAlerts = budgetAlerts
  }

  /// Whether these are the values a device starts with, which is what decides a first sync: an
  /// Account with no row takes them only when the device has something of its own to say. A
  /// selector that was edited to the default pair still counts as something.
  public var isDefault: Bool {
    resetReminders == AlertRules.defaultResetReminders
      && paceAlerts == AlertRules.defaultPaceAlerts
      && thresholds.isEmpty
      && budgetAmountUSD == nil
      && budgetAlerts == UsageBudget.none.alerts
  }
}

/// One edit a client just made locally, kept so it can be replayed after a 412.
public enum AccountSettingsEdit: Equatable, Sendable {
  case setResetReminders(Bool)
  case setPaceAlerts(Bool)
  case setThresholds(selector: String, [Int])
  /// The amount and its switch move together, because a budget editor writes one `UsageBudget`.
  case setBudget(amount: Decimal?, alerts: Bool)
}

/// What a device does the first time it sees the Account's copy of the policy.
public enum AccountSettingsFirstSync: Equatable, Sendable {
  /// The Account has no row and this device has something to say: write the document at
  /// `If-Match: "<write.revision>"`. A 412 means another device won, so adopt that answer instead.
  case seed(write: AccountSettingsDocument)
  /// The Account wins and nothing is written.
  case adopt(policy: AccountSettingsPolicy)
  /// The Account wins, and the selectors it does not name are added to it once.
  case adoptAndMerge(policy: AccountSettingsPolicy, write: AccountSettingsDocument)

  /// The values this device applies to its stores.
  public var policy: AccountSettingsPolicy {
    switch self {
    case .seed(let write): write.policy
    case .adopt(let policy): policy
    case .adoptAndMerge(let policy, _): policy
    }
  }

  /// The document to write, when the plan has one.
  public var write: AccountSettingsDocument? {
    switch self {
    case .seed(let write): write
    case .adopt: nil
    case .adoptAndMerge(_, let write): write
    }
  }
}

extension AccountSettingsPolicy {
  /// This device's effective values, read out of the two stores that hold them. A local list of
  /// more than two thresholds is not a shape the document takes, so the largest two travel.
  public init(rules: AlertRules, budget: UsageBudget) {
    self.init(
      resetReminders: rules.resetReminders,
      paceAlerts: rules.paceAlerts,
      thresholds: rules.thresholds.mapValues(AccountSettings.wireThresholds),
      budgetAmountUSD: budget.amountUSD,
      budgetAlerts: budget.alerts
    )
  }
}

extension AccountSettingsDocument {
  /// The document these policy values write, at the revision the write states in `If-Match`.
  public init(policy: AccountSettingsPolicy, revision: Int) {
    self.init(
      revision: revision,
      alerts: Alerts(
        resetReminders: policy.resetReminders,
        paceAlerts: policy.paceAlerts,
        thresholds: policy.thresholds
      ),
      budget: Budget(amountUSD: policy.budgetAmountUSD, alerts: policy.budgetAlerts)
    )
  }

  /// The policy fields this document carries.
  public var policy: AccountSettingsPolicy {
    AccountSettingsPolicy(
      resetReminders: alerts.resetReminders,
      paceAlerts: alerts.paceAlerts,
      thresholds: alerts.thresholds,
      budgetAmountUSD: budget.amountUSD,
      budgetAlerts: budget.alerts
    )
  }
}

extension AlertRules {
  /// These rules with the Account's policy applied. `enabled` is kept: it is this device's
  /// notification permission, the document does not carry it, and a device the system denied must
  /// not have alerts switched back on by another device.
  public func applying(_ policy: AccountSettingsPolicy) -> AlertRules {
    AlertRules(
      enabled: enabled,
      resetReminders: policy.resetReminders,
      paceAlerts: policy.paceAlerts,
      thresholds: policy.thresholds
    )
  }
}

extension UsageBudget {
  /// The budget the Account's policy names. A budget has no per-device half to keep.
  public init(policy: AccountSettingsPolicy) {
    self.init(amountUSD: policy.budgetAmountUSD, alerts: policy.budgetAlerts)
  }
}
