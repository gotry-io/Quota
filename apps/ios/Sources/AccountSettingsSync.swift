import Foundation
import QuotaAccount
import QuotaAlertDelivery
import QuotaAlerts
import QuotaPresentation

/// Owns the Account settings document on this phone: first sync, local edits, and the one
/// 412 retry ([ADR 0061](../../../docs/decisions/0061-alert-policy-and-the-budget-follow-the-account.md)).
///
/// Effective values stay in the shipped `alerts.*` and `usage.budget.*` keys. `enabled` is never
/// written here. Un-acknowledged local edits are an ordered list per Account, coalesced by
/// target, folded into one PUT, and retried on the next refresh. Sign-out clears the last-good
/// cache (on `AccountClient`) and leaves those UserDefaults values in place.
@MainActor
@Observable
final class AccountSettingsSync {
  nonisolated static let firstSyncKey = "accountSettings.firstSyncAccountIDs"
  /// Pre-FIX1 single-record key. Load migrates it into `pendingEditsKey` and deletes it.
  nonisolated static let pendingKey = "accountSettings.pendingEdit"
  nonisolated static let pendingEditsKey = "accountSettings.pendingEdits"

  private let account: AccountClient
  private let rulesStore: AlertRulesStore
  private let budgetStore: UsageBudgetStore
  private let defaults: UserDefaults
  /// When false, local apply still runs and nothing is read or written on Relay. Tests that
  /// script unrelated HTTP use this so a settings GET does not consume their exchanges.
  private let connectsToAccount: Bool

  /// True while `AppModel.phase` is `signedIn`.
  @ObservationIgnored var isSignedIn: () -> Bool = { false }
  /// After any applied change — local or remote — so evaluation and reset reminders run now,
  /// not at the next refresh.
  @ObservationIgnored var onApplied: () -> Void = {}

  /// Bumped after every apply so a view-scoped `SettingsModel` can reload from the stores.
  private(set) var generation = 0
  /// Un-acknowledged local edits, oldest first, any Account this phone has queued for.
  private(set) var pending: [PendingAccountSettingsEdit] = []
  private var nextPendingID: UInt64 = 1

  private var chain: Task<Void, Never> = Task {}

  init(
    account: AccountClient,
    rulesStore: AlertRulesStore,
    budgetStore: UsageBudgetStore,
    defaults: UserDefaults = .standard,
    connectsToAccount: Bool = true
  ) {
    self.account = account
    self.rulesStore = rulesStore
    self.budgetStore = budgetStore
    self.defaults = defaults
    self.connectsToAccount = connectsToAccount
    let loaded = PendingAccountSettingsEdit.loadQueue(from: defaults)
    self.pending = loaded.items
    self.nextPendingID = loaded.nextID
  }

  /// Read on sign-in and on each Account refresh. First time for this Account runs
  /// `AccountSettings.planFirstSync`; later reads adopt when the revision moved, except a
  /// pending list is folded over the fetched document instead of a raw adopt.
  func refresh() async {
    await enqueue { await self.performRefresh() }
  }

  /// Apply locally at once, queue the edit, then PUT every pending edit for this Account as
  /// one document. A 412 folds that same snapshot onto the fresh document and retries once.
  func apply(_ edit: AccountSettingsEdit) async {
    applyLocally(edit)
    notifyApplied()
    if connectsToAccount, isSignedIn(), let session = try? await account.loadSession() {
      rememberPending(accountID: session.accountID, edit: edit)
    }
    await enqueue { await self.performPush() }
  }

  /// Current policy as the stores hold it. `enabled` is not included.
  func currentPolicy() -> AccountSettingsPolicy {
    AccountSettingsPolicy(rules: rulesStore.load(), budget: budgetStore.load())
  }

  func pendingEdits(for accountID: String) -> [PendingAccountSettingsEdit] {
    pending.filter { $0.accountID == accountID }
  }

  private func enqueue(_ work: @escaping @MainActor () async -> Void) async {
    let previous = chain
    let next = Task { @MainActor in
      await previous.value
      await work()
    }
    chain = next
    await next.value
  }

  private func performRefresh() async {
    guard connectsToAccount, isSignedIn() else { return }
    guard let session = try? await account.loadSession() else { return }
    let accountID = session.accountID
    let previous = try? await account.loadCachedSettings()
    let fetched: AccountSettingsDocument
    let etag: String?
    do {
      (fetched, etag) = try await account.fetchAccountSettings()
    } catch {
      return
    }
    if !hasCompletedFirstSync(accountID) {
      await runFirstSync(accountID: accountID, account: fetched, etag: etag)
      if hasCompletedFirstSync(accountID) {
        await pushPending(accountID: accountID)
      }
      return
    }
    let mine = pendingEdits(for: accountID)
    if !mine.isEmpty {
      applyPolicy(Self.folding(mine.map(\.edit), onto: fetched).policy)
      notifyApplied()
      await pushPending(accountID: accountID, onto: fetched, etag: etag, retryOnConflict: true)
      return
    }
    if previous?.document.revision != fetched.revision {
      applyPolicy(fetched.policy)
      notifyApplied()
    }
  }

  private func performPush() async {
    guard connectsToAccount, isSignedIn() else { return }
    guard let session = try? await account.loadSession() else { return }
    await pushPending(accountID: session.accountID)
  }

  private func runFirstSync(
    accountID: String,
    account document: AccountSettingsDocument,
    etag: String?
  ) async {
    let plan = AccountSettings.planFirstSync(local: currentPolicy(), account: document)
    applyPolicy(plan.policy)
    notifyApplied()
    guard let write = plan.write else {
      markFirstSync(accountID)
      return
    }
    let seed = Self.folding(pendingEdits(for: accountID).map(\.edit), onto: write)
    do {
      let result = try await account.writeAccountSettings(
        seed,
        ifMatch: Self.matchTag(etag: etag, revision: write.revision)
      )
      switch result {
      case .written(let written, _):
        applyPolicy(
          Self.folding(pendingEdits(for: accountID).map(\.edit), onto: written).policy
        )
        notifyApplied()
        markFirstSync(accountID)
      case .conflict(let current, _):
        applyPolicy(
          Self.folding(pendingEdits(for: accountID).map(\.edit), onto: current).policy
        )
        notifyApplied()
        markFirstSync(accountID)
      }
    } catch {
      return
    }
  }

  private func pushPending(accountID: String) async {
    let mine = pendingEdits(for: accountID)
    guard !mine.isEmpty else { return }
    if let cached = try? await account.loadCachedSettings() {
      await pushPending(
        accountID: accountID,
        onto: cached.document,
        etag: cached.etag,
        retryOnConflict: true
      )
      return
    }
    do {
      let (document, etag) = try await account.fetchAccountSettings()
      await pushPending(
        accountID: accountID,
        onto: document,
        etag: etag,
        retryOnConflict: true
      )
    } catch {
      return
    }
  }

  private func pushPending(
    accountID: String,
    onto base: AccountSettingsDocument,
    etag: String?,
    retryOnConflict: Bool
  ) async {
    let snapshot = pendingEdits(for: accountID)
    await send(
      snapshot,
      accountID: accountID,
      onto: base,
      etag: etag,
      retryOnConflict: retryOnConflict
    )
  }

  private func send(
    _ snapshot: [PendingAccountSettingsEdit],
    accountID: String,
    onto base: AccountSettingsDocument,
    etag: String?,
    retryOnConflict: Bool
  ) async {
    guard !snapshot.isEmpty else { return }
    let write = Self.folding(snapshot.map(\.edit), onto: base)
    do {
      let result = try await account.writeAccountSettings(
        write,
        ifMatch: Self.matchTag(etag: etag, revision: write.revision)
      )
      switch result {
      case .written(let document, _):
        removePending(ids: Set(snapshot.map(\.id)))
        applyPolicy(
          Self.folding(pendingEdits(for: accountID).map(\.edit), onto: document).policy
        )
        notifyApplied()
      case .conflict(let current, let conflictETag):
        applyPolicy(
          Self.folding(pendingEdits(for: accountID).map(\.edit), onto: current).policy
        )
        notifyApplied()
        if retryOnConflict {
          await send(
            snapshot,
            accountID: accountID,
            onto: current,
            etag: conflictETag,
            retryOnConflict: false
          )
        }
      }
    } catch {
      return
    }
  }

  /// One document carrying every edit, in queue order.
  static func folding(
    _ edits: [AccountSettingsEdit],
    onto base: AccountSettingsDocument
  ) -> AccountSettingsDocument {
    edits.reduce(base) { AccountSettings.reapply(edit: $1, onto: $0) }
  }

  func applyLocally(_ edit: AccountSettingsEdit) {
    var rules = rulesStore.load()
    switch edit {
    case .setResetReminders(let value):
      rules.resetReminders = value
      rulesStore.save(rules)
    case .setPaceAlerts(let value):
      rules.paceAlerts = value
      rulesStore.save(rules)
    case .setThresholds(let selector, let values):
      rules.setThresholds(values, for: selector)
      rulesStore.save(rules)
    case .setBudget(let amount, let alerts):
      budgetStore.save(UsageBudget(amountUSD: amount, alerts: alerts))
    case .setHistorySync:
      break
    }
  }

  func applyPolicy(_ policy: AccountSettingsPolicy) {
    rulesStore.save(rulesStore.load().applying(policy))
    budgetStore.save(UsageBudget(policy: policy))
  }

  private func notifyApplied() {
    generation += 1
    onApplied()
  }

  private func hasCompletedFirstSync(_ accountID: String) -> Bool {
    (defaults.stringArray(forKey: Self.firstSyncKey) ?? []).contains(accountID)
  }

  private func markFirstSync(_ accountID: String) {
    var ids = defaults.stringArray(forKey: Self.firstSyncKey) ?? []
    if !ids.contains(accountID) {
      ids.append(accountID)
      defaults.set(ids, forKey: Self.firstSyncKey)
    }
  }

  private func rememberPending(accountID: String, edit: AccountSettingsEdit) {
    let target = PendingAccountSettingsEdit.Target(edit)
    pending.removeAll { $0.accountID == accountID && $0.target == target }
    let item = PendingAccountSettingsEdit(id: nextPendingID, accountID: accountID, edit: edit)
    nextPendingID += 1
    pending.append(item)
    persistPending()
  }

  private func removePending(ids: Set<UInt64>) {
    pending.removeAll { ids.contains($0.id) }
    persistPending()
  }

  private func persistPending() {
    PendingAccountSettingsEdit.saveQueue(items: pending, nextID: nextPendingID, to: defaults)
  }

  /// `If-Match` is the ETag the last GET/PUT answered, or `"<revision>"` when that header was
  /// missing, which is how Relay spells it.
  static func matchTag(etag: String?, revision: Int) -> String {
    if let etag, !etag.isEmpty { return etag }
    return "\"\(revision)\""
  }
}

/// One queued local edit, persisted so an offline write is retried after relaunch.
struct PendingAccountSettingsEdit: Equatable, Sendable {
  var id: UInt64
  var accountID: String
  var edit: AccountSettingsEdit

  enum Target: Equatable, Sendable {
    case resetReminders
    case paceAlerts
    case thresholds(String)
    case budget
    case historySync
  }

  var target: Target { Target(edit) }
}

extension PendingAccountSettingsEdit.Target {
  init(_ edit: AccountSettingsEdit) {
    switch edit {
    case .setResetReminders: self = .resetReminders
    case .setPaceAlerts: self = .paceAlerts
    case .setThresholds(let selector, _): self = .thresholds(selector)
    case .setBudget: self = .budget
    case .setHistorySync: self = .historySync
    }
  }
}

extension PendingAccountSettingsEdit {
  fileprivate struct Queue: Equatable {
    var items: [PendingAccountSettingsEdit]
    var nextID: UInt64
  }

  static func saveQueueForTests(
    items: [PendingAccountSettingsEdit],
    nextID: UInt64,
    to defaults: UserDefaults
  ) {
    saveQueue(items: items, nextID: nextID, to: defaults)
  }

  fileprivate static func saveQueue(
    items: [PendingAccountSettingsEdit],
    nextID: UInt64,
    to defaults: UserDefaults
  ) {
    defaults.removeObject(forKey: AccountSettingsSync.pendingKey)
    if items.isEmpty {
      defaults.removeObject(forKey: AccountSettingsSync.pendingEditsKey)
      return
    }
    let file = PendingEditsFile(nextID: nextID, items: items.map(PendingAccountSettingsEditRecord.init))
    guard let data = try? JSONEncoder().encode(file) else { return }
    defaults.set(data, forKey: AccountSettingsSync.pendingEditsKey)
  }

  fileprivate static func loadQueue(from defaults: UserDefaults) -> Queue {
    if let data = defaults.data(forKey: AccountSettingsSync.pendingEditsKey),
      let file = try? JSONDecoder().decode(PendingEditsFile.self, from: data)
    {
      defaults.removeObject(forKey: AccountSettingsSync.pendingKey)
      let items = file.items.compactMap(\.value)
      let nextID = max(file.nextID, (items.map(\.id).max() ?? 0) + 1)
      return Queue(items: items, nextID: nextID)
    }
    if let data = defaults.data(forKey: AccountSettingsSync.pendingKey),
      let record = try? JSONDecoder().decode(PendingAccountSettingsEditRecord.self, from: data),
      let item = record.value
    {
      let migrated = PendingAccountSettingsEdit(id: 1, accountID: item.accountID, edit: item.edit)
      saveQueue(items: [migrated], nextID: 2, to: defaults)
      return Queue(items: [migrated], nextID: 2)
    }
    defaults.removeObject(forKey: AccountSettingsSync.pendingKey)
    return Queue(items: [], nextID: 1)
  }
}

private struct PendingEditsFile: Codable {
  var nextID: UInt64
  var items: [PendingAccountSettingsEditRecord]

  enum CodingKeys: String, CodingKey {
    case nextID = "next_id"
    case items
  }
}

private struct PendingAccountSettingsEditRecord: Codable {
  var id: UInt64?
  var accountID: String
  var kind: Kind
  var boolValue: Bool?
  var selector: String?
  var thresholds: [Int]?
  var amountUSD: String?
  var budgetAlerts: Bool?

  enum Kind: String, Codable {
    case resetReminders
    case paceAlerts
    case thresholds
    case budget
    case historySync
  }

  init(_ pending: PendingAccountSettingsEdit) {
    id = pending.id
    accountID = pending.accountID
    switch pending.edit {
    case .setResetReminders(let value):
      kind = .resetReminders
      boolValue = value
    case .setPaceAlerts(let value):
      kind = .paceAlerts
      boolValue = value
    case .setThresholds(let selector, let values):
      kind = .thresholds
      self.selector = selector
      thresholds = values
    case .setBudget(let amount, let alerts):
      kind = .budget
      amountUSD = amount.map { NSDecimalNumber(decimal: $0).stringValue }
      budgetAlerts = alerts
    case .setHistorySync(let value):
      kind = .historySync
      boolValue = value
    }
  }

  var value: PendingAccountSettingsEdit? {
    let edit: AccountSettingsEdit
    switch kind {
    case .resetReminders:
      guard let boolValue else { return nil }
      edit = .setResetReminders(boolValue)
    case .paceAlerts:
      guard let boolValue else { return nil }
      edit = .setPaceAlerts(boolValue)
    case .thresholds:
      guard let selector, let thresholds else { return nil }
      edit = .setThresholds(selector: selector, thresholds)
    case .budget:
      guard let budgetAlerts else { return nil }
      let amount = amountUSD.flatMap {
        Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX"))
      }
      edit = .setBudget(amount: amount, alerts: budgetAlerts)
    case .historySync:
      guard let boolValue else { return nil }
      edit = .setHistorySync(boolValue)
    }
    return PendingAccountSettingsEdit(id: id ?? 1, accountID: accountID, edit: edit)
  }
}
