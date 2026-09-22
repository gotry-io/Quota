import Foundation
import Observation
import QuotaAlerts

/// The IPC calls Account settings sync makes. The rest of the local service stays on
/// the app coordinator.
protocol AccountSettingsTransport: Sendable {
  func setAccountSettings(document: AccountSettingsDocument, ifMatch: String) async throws
    -> LocalServiceAccountSettingsWriteResult
  func refreshAccountSettings() async throws -> LocalServiceAccountSettingsState
}

/// Seed, adopt, merge, and 412 re-apply of the Account settings document. Effective values stay
/// in the shipped `notifications.*` and `UsageBudgetStore` keys; this owner decides what to
/// persist and what to write.
///
/// Pending edits are an ordered list per Account id, persisted in `UserDefaults`. A write folds
/// every pending edit for the signed-in Account over the base document. Success clears only the
/// edits that were sent; an edit that arrived mid-flight stays queued. First-sync Account ids
/// are persisted so a relaunch does not adopt over an offline edit.
@Observable
@MainActor
final class AccountSettingsModel {
  static let firstSyncKey = "accountSettings.firstSyncAccountIDs"
  static let pendingKey = "accountSettings.pendingEdits"

  private var firstSyncedAccountIDs: Set<String>
  private var pendingByAccount: [String: [AccountSettingsEdit]]
  private var signedInAccountID: String?
  /// The Account local edits attach to while signed out, so they are not dropped and are not
  /// sent for a later Account.
  private var lastAccountID: String?
  private var known: LocalServiceAccountSettingsState?
  /// The history switch the signed-in Account currently holds, including an edit not yet written.
  private(set) var historySync = false

  @ObservationIgnored
  private var writeTask: Task<Void, Never>?

  /// Invalidates an in-flight write so its result does not land after sign-out.
  @ObservationIgnored
  private var writeGeneration: UInt64 = 0

  @ObservationIgnored
  private var queuedState: LocalServiceState?

  @ObservationIgnored
  private let transport: (any AccountSettingsTransport)?

  @ObservationIgnored
  private let defaults: UserDefaults

  @ObservationIgnored
  var currentPolicy: () -> AccountSettingsPolicy = {
    AccountSettingsPolicy(rules: AlertRules(), budget: .none)
  }

  @ObservationIgnored
  var applyPolicy: (AccountSettingsPolicy) -> Void = { _ in }

  @ObservationIgnored
  var sessionEpoch: () -> Int = { 0 }

  @ObservationIgnored
  var onNeedsReload: (@MainActor () async -> Void)?

  init(transport: (any AccountSettingsTransport)?, defaults: UserDefaults = .standard) {
    self.transport = transport
    self.defaults = defaults
    firstSyncedAccountIDs = Set(defaults.stringArray(forKey: Self.firstSyncKey) ?? [])
    pendingByAccount = Self.loadPending(from: defaults)
  }

  deinit {
    writeTask?.cancel()
  }

  func shutdown() {
    writeGeneration += 1
    writeTask?.cancel()
    writeTask = nil
    queuedState = nil
  }

  /// Drops in-flight writes so a result that lands after sign-out writes nothing. Local values,
  /// the first-sync set, and pending queues stay.
  func accountDidGoAway() {
    writeGeneration += 1
    writeTask?.cancel()
    writeTask = nil
    queuedState = nil
    signedInAccountID = nil
    known = nil
    historySync = false
  }

  /// Takes the Account settings slice of an accepted `get_state`.
  func accountSettingsAccepted(_ state: LocalServiceState) {
    let auth = state.account.value?.authStatus
    let signedIn = auth == .signedIn || auth == .logoutPending
    guard signedIn, let accountID = state.account.value?.accountID else {
      if signedInAccountID != nil {
        accountDidGoAway()
      }
      return
    }
    if writeTask != nil {
      queuedState = state
      return
    }
    process(state, accountID: accountID)
  }

  func noteLocalEdit(_ edit: AccountSettingsEdit) {
    let accountID = signedInAccountID ?? lastAccountID
    guard let accountID else { return }
    if case .setHistorySync(let enabled) = edit {
      historySync = enabled
    }
    enqueue(edit, for: accountID)
    if signedInAccountID == accountID {
      schedulePendingWrite()
    }
  }

  /// Visual QA and tests that need the switch on without a settings write.
  func applyVisualHistorySync(_ enabled: Bool) {
    historySync = enabled
  }

  private func process(_ state: LocalServiceState, accountID: String) {
    if signedInAccountID != accountID {
      signedInAccountID = accountID
      known = nil
    }
    lastAccountID = accountID
    guard let settings = state.accountSettings else { return }

    let pending = pendingByAccount[accountID] ?? []

    if !firstSyncedAccountIDs.contains(accountID) {
      let plan = AccountSettings.planFirstSync(local: currentPolicy(), account: settings.document)
      if pending.isEmpty {
        adoptPolicy(plan.policy)
        if let write = plan.write {
          known = LocalServiceAccountSettingsState(
            document: write, revision: write.revision)
          scheduleFirstSyncWrite(write)
        } else {
          markFirstSynced(accountID)
          known = settings
        }
      } else {
        let base = plan.write ?? settings.document
        let folded = Self.fold(pending, over: base)
        adoptPolicy(folded.policy)
        known = LocalServiceAccountSettingsState(document: base, revision: base.revision)
        schedulePendingWrite(markFirstSyncOnSuccess: true)
      }
      return
    }

    if !pending.isEmpty {
      let incomingNewer = settings.revision > (known?.revision ?? -1)
      let base = incomingNewer ? settings.document : (known?.document ?? settings.document)
      if incomingNewer {
        known = settings
      }
      adoptPolicy(Self.fold(pending, over: base).policy)
      schedulePendingWrite()
      return
    }

    if settings.revision > (known?.revision ?? -1) {
      adoptPolicy(settings.document.policy)
      known = settings
    }
  }

  private func adoptPolicy(_ policy: AccountSettingsPolicy) {
    historySync = policy.historySync
    applyPolicy(policy)
  }

  private func schedulePendingWrite(markFirstSyncOnSuccess: Bool = false) {
    guard writeTask == nil, signedInAccountID != nil, known != nil, transport != nil else {
      return
    }
    writeTask = Task { @MainActor [weak self] in
      await self?.performPendingWrite(markFirstSyncOnSuccess: markFirstSyncOnSuccess)
    }
  }

  private func scheduleFirstSyncWrite(_ document: AccountSettingsDocument) {
    guard writeTask == nil, transport != nil else { return }
    writeTask = Task { @MainActor [weak self] in
      await self?.performFirstSyncWrite(document)
    }
  }

  private func performPendingWrite(markFirstSyncOnSuccess: Bool) async {
    guard let transport, let accountID = signedInAccountID, let known else {
      writeTask = nil
      return
    }
    let sent = pendingByAccount[accountID] ?? []
    guard !sent.isEmpty else {
      writeTask = nil
      return
    }
    let generation = writeGeneration
    let epoch = sessionEpoch()
    var document = Self.fold(sent, over: known.document)
    var ifMatch = known.ifMatch
    var retrying = false
    while true {
      let result: LocalServiceAccountSettingsWriteResult
      do {
        result = try await transport.setAccountSettings(document: document, ifMatch: ifMatch)
      } catch is CancellationError {
        return
      } catch {
        guard writeGeneration == generation, epoch == sessionEpoch() else { return }
        writeTask = nil
        flushQueuedState()
        return
      }
      guard writeGeneration == generation, epoch == sessionEpoch() else { return }
      switch result {
      case .written(let written):
        self.known = LocalServiceAccountSettingsState(
          document: written, revision: written.revision)
        removeSent(sent, from: accountID)
        if markFirstSyncOnSuccess {
          markFirstSynced(accountID)
        }
        writeTask = nil
        queuedState = nil
        await onNeedsReload?()
        if writeTask == nil, signedInAccountID == accountID,
          !(pendingByAccount[accountID] ?? []).isEmpty
        {
          schedulePendingWrite()
        } else {
          flushQueuedState()
        }
        return
      case .conflict(let current):
        self.known = LocalServiceAccountSettingsState(
          document: current, revision: current.revision)
        if retrying {
          writeTask = nil
          flushQueuedState()
          return
        }
        document = Self.fold(sent, over: current)
        adoptPolicy(document.policy)
        ifMatch = LocalServiceAccountSettingsState.ifMatch(current.revision)
        retrying = true
      }
    }
  }

  private func performFirstSyncWrite(_ document: AccountSettingsDocument) async {
    guard let transport, let accountID = signedInAccountID else {
      writeTask = nil
      return
    }
    let generation = writeGeneration
    let epoch = sessionEpoch()
    let ifMatch = LocalServiceAccountSettingsState.ifMatch(document.revision)
    let result: LocalServiceAccountSettingsWriteResult
    do {
      result = try await transport.setAccountSettings(document: document, ifMatch: ifMatch)
    } catch is CancellationError {
      return
    } catch {
      guard writeGeneration == generation, epoch == sessionEpoch() else { return }
      writeTask = nil
      flushQueuedState()
      return
    }
    guard writeGeneration == generation, epoch == sessionEpoch() else { return }
    writeTask = nil
    switch result {
    case .written(let written):
      known = LocalServiceAccountSettingsState(document: written, revision: written.revision)
      markFirstSynced(accountID)
      queuedState = nil
      await onNeedsReload?()
    case .conflict(let current):
      adoptPolicy(current.policy)
      known = LocalServiceAccountSettingsState(document: current, revision: current.revision)
      markFirstSynced(accountID)
    }
    if writeTask == nil {
      flushQueuedState()
    }
  }

  private func enqueue(_ edit: AccountSettingsEdit, for accountID: String) {
    var queue = pendingByAccount[accountID] ?? []
    let target = Self.target(edit)
    if let index = queue.firstIndex(where: { Self.target($0) == target }) {
      queue[index] = edit
    } else {
      queue.append(edit)
    }
    pendingByAccount[accountID] = queue
    persistPending()
  }

  private func removeSent(_ sent: [AccountSettingsEdit], from accountID: String) {
    var queue = pendingByAccount[accountID] ?? []
    for edit in sent {
      if let index = queue.firstIndex(of: edit) {
        queue.remove(at: index)
      }
    }
    if queue.isEmpty {
      pendingByAccount.removeValue(forKey: accountID)
    } else {
      pendingByAccount[accountID] = queue
    }
    persistPending()
  }

  private func markFirstSynced(_ accountID: String) {
    firstSyncedAccountIDs.insert(accountID)
    defaults.set(Array(firstSyncedAccountIDs).sorted(), forKey: Self.firstSyncKey)
  }

  private func persistPending() {
    defaults.set(Self.encodePending(pendingByAccount), forKey: Self.pendingKey)
  }

  private func flushQueuedState() {
    guard let queued = queuedState else { return }
    queuedState = nil
    accountSettingsAccepted(queued)
  }

  private static func fold(
    _ edits: [AccountSettingsEdit],
    over base: AccountSettingsDocument
  ) -> AccountSettingsDocument {
    edits.reduce(base) { AccountSettings.reapply(edit: $1, onto: $0) }
  }

  private enum EditTarget: Equatable {
    case resetReminders
    case paceAlerts
    case budget
    case thresholds(String)
    case historySync
  }

  private static func target(_ edit: AccountSettingsEdit) -> EditTarget {
    switch edit {
    case .setResetReminders: .resetReminders
    case .setPaceAlerts: .paceAlerts
    case .setBudget: .budget
    case .setThresholds(let selector, _): .thresholds(selector)
    case .setHistorySync: .historySync
    }
  }

  private static func loadPending(from defaults: UserDefaults) -> [String: [AccountSettingsEdit]] {
    guard let data = defaults.data(forKey: pendingKey) else { return [:] }
    guard let encoded = try? JSONDecoder().decode([String: [PersistedEdit]].self, from: data)
    else {
      return [:]
    }
    return encoded.mapValues { $0.compactMap(\.edit) }
  }

  private static func encodePending(_ pending: [String: [AccountSettingsEdit]]) -> Data {
    let encoded = pending.mapValues { $0.map(PersistedEdit.init) }
    return (try? JSONEncoder().encode(encoded)) ?? Data("{}".utf8)
  }
}

/// JSON form of one queued edit. Keys are literal snake_case so a relaunch can read them back.
private struct PersistedEdit: Codable {
  var type: String
  var value: Bool?
  var selector: String?
  var values: [Int]?
  var amountUSD: String?
  var alerts: Bool?

  enum CodingKeys: String, CodingKey {
    case type
    case value
    case selector
    case values
    case amountUSD = "amount_usd"
    case alerts
  }

  init(_ edit: AccountSettingsEdit) {
    switch edit {
    case .setResetReminders(let value):
      type = "reset_reminders"
      self.value = value
    case .setPaceAlerts(let value):
      type = "pace_alerts"
      self.value = value
    case .setThresholds(let selector, let values):
      type = "thresholds"
      self.selector = selector
      self.values = values
    case .setBudget(let amount, let alerts):
      type = "budget"
      amountUSD = amount.map(Self.wireAmount)
      self.alerts = alerts
    case .setHistorySync(let enabled):
      type = "history_sync"
      value = enabled
    }
  }

  var edit: AccountSettingsEdit? {
    switch type {
    case "reset_reminders":
      return value.map { .setResetReminders($0) }
    case "pace_alerts":
      return value.map { .setPaceAlerts($0) }
    case "thresholds":
      guard let selector, let values else { return nil }
      return .setThresholds(selector: selector, values)
    case "budget":
      guard let alerts else { return nil }
      let amount = amountUSD.flatMap { Decimal(string: $0, locale: Self.posix) }
      return .setBudget(amount: amount, alerts: alerts)
    case "history_sync":
      return value.map { .setHistorySync($0) }
    default:
      return nil
    }
  }

  private static let posix = Locale(identifier: "en_US_POSIX")

  private static func wireAmount(_ amount: Decimal) -> String {
    var scaled = amount * 100
    var rounded = Decimal()
    NSDecimalRound(&rounded, &scaled, 0, .plain)
    let cents = NSDecimalNumber(decimal: rounded).intValue
    let fraction = abs(cents % 100)
    return "\(cents / 100).\(fraction < 10 ? "0" : "")\(fraction)"
  }
}
