import AuthenticationServices
import Foundation
import Observation
import UIKit
import QuotaAccount
import QuotaAlertDelivery
import QuotaAlerts
import QuotaPresentation
import QuotaProviderSessions
import QuotaProviderStatus
import QuotaRelay
import QuotaWidgetData
import QuotaWidgetProjection
import QuotaWire

@MainActor
@Observable
final class AppModel {
  /// Where this app is with the managed Account. It is not whether the app is usable: since
  /// [ADR 0034](../../../docs/decisions/0034-ios-collects-for-itself.md) this phone collects for
  /// itself, so `signedOut` still shows tabs and whatever it read here.
  enum Phase: Equatable, Hashable {
    case launching
    case signedOut
    case connecting
    case confirmingAccount(label: String)
    case pendingRefreshFailed
    case signedIn
  }

  /// What the Sign-in methods group has to show. A failed read is not a signed-out Account and
  /// not an empty list, so it is a state of its own rather than an empty array.
  enum IdentitiesPhase: Equatable {
    case idle
    case loading
    case loaded([AccountIdentity])
    case failed

    var identities: [AccountIdentity] {
      if case .loaded(let identities) = self { return identities }
      return []
    }
  }

  enum BannerKind: Equatable {
    case offlineCached
    case refreshFailed
  }

  struct Banner: Equatable {
    var kind: BannerKind
    var text: String
    var symbolName: String

    static let cachedText = "Showing saved data. Couldn't refresh."
    static let failedText = "Couldn't refresh. Pull to try again."
  }

  private let account: AccountClient
  private let authenticator: any BrowserSessionAuthenticating
  private let makeAuthorizationAttempt: @Sendable () throws -> AuthorizationAttempt
  private let widgetPublisher: any WidgetSnapshotPublishing
  private let selectionSaltStore: any SelectionSaltStore
  private let backgroundRefresh: any BackgroundRefreshScheduling
  private let alertCoordinator: AlertCoordinator
  private let userNotificationSink: UserNotificationAlertSink?
  private let resetScheduler: ResetReminderScheduler
  private let localStore: any LocalCollectionStoring
  private let sampleStore: any LocalQuotaSampleStoring
  private let localCollector: LocalCollector
  let quotaHistory: QuotaHistoryCoordinator
  private let installation: any InstallationIdentifying
  private let providerStatusClient: any ProviderStatusServing
  private let now: @Sendable () -> Date
  /// How the collection follow-up waits between summary reads. Tests answer it at once.
  private let demandSleep: @Sendable (Duration) async throws -> Void

  /// The provider sessions this phone signed in for, and the consent behind them. Settings owns
  /// the rows; the sessions themselves are the Keychain store's.
  let providers: ProvidersModel
  /// Selected Usage range, activity/rhythm/day reads, and this device's copy of the monthly budget.
  let usage: UsageModel
  /// Alert policy and the budget as the Account settings document. No forwarding accessors.
  let accountSettings: AccountSettingsSync

  var phase: Phase = .launching
  var summary: AccountSummary?
  /// What this iPhone last read from the providers it signed in to. Kept across launches so a
  /// phone that opens offline still shows the quota it knows.
  var localCollection: LocalCollection?
  /// What this phone has read of its own quota over time, and only its own: a reading that came
  /// from an Account was taken by some other device and leaves no sample here (ADR 0042).
  var localSamples = LocalQuotaSamples()
  var fetchedAt: Date?
  var fromCache = false
  var isRefreshing = false
  /// While a refresh runs: the provider sessions whose reading has not come back in this pass.
  /// Their rows say so in place, and their last reading stays on screen until it does.
  private(set) var pendingReadings: Set<String> = []
  /// While a refresh runs: the Account summary has been asked for and has not answered yet.
  private(set) var awaitsSummary = false
  /// How many reads this refresh started: one per provider session, and the summary.
  private(set) var refreshReads = 0
  /// The local cache has been read. The launch mark waits for this and for nothing on the network.
  private(set) var hasRestoredLocalState = false
  /// Restore found something to read and the refresh that reads it has not finished yet.
  private(set) var awaitsFirstRefresh = false
  var banner: Banner?
  var expiredMessage: String?
  var selectedTab: AppTab = .quota
  /// Selection id from a subscription deep link, held until a summary can name it.
  var pendingSubscriptionSelection: String?
  /// Subscription keys on the Overview stack. A matching deep link replaces this with one key.
  var overviewPath: [String] = []
  /// Usage stack destinations (`breakdown`, `patterns`). Empty is the Usage hub.
  var usagePath: [UsageDestination] = []
  /// Settings stack destinations. Empty is the Settings hub.
  var settingsPath: [SettingsDestination] = []
  /// The validator the last applied summary was current at, when the read carried one.
  var summaryETag: String?
  /// Incremented when the account goes away so in-flight Usage reads drop their completion.
  @ObservationIgnored private(set) var accountSessionEpoch = 0
  /// The managed Account session this device holds, and how far along it is.
  private(set) var sessionActivation: AccountSessionActivation?
  /// The Device this phone's session speaks for, or nil when it registered none. Devices lists
  /// that row as the Account's rather than synthesizing a second one beside it.
  var sessionDeviceID: String?
  /// The nonce the Sign in with Apple request in flight is bound to. Apple was handed its digest.
  private var appleNonce: AppleSignInNonce?
  /// Whether the sign-in sheet — the one page that offers every way in — is showing.
  var presentsSignIn = false
  /// The browser round trip this app is waiting on, and the verifier only it can spend.
  ///
  /// It is cleared by whichever end answers first: the session sheet, or the authorization
  /// callback an emailed sign-in link sends back through the system browser. Kept in memory
  /// alone, so a relaunch while the person is in their mail app has nothing to exchange.
  private var pendingWebSignIn: AuthorizationAttempt?
  /// The channels that reach this Account, as Relay last answered. Read when Settings asks.
  var identities: IdentitiesPhase = .idle
  /// The channel a native bind is in flight for, so its row draws the busy state.
  var linkingProvider: IdentityProvider?
  /// Why the last bind did not happen, said under the Sign-in methods group.
  var linkFailure: String?
  /// Last-good official status-page readings. Restored from disk, then refreshed from Relay's
  /// public catalog (`GET /api/v2/providers/status`) with direct Statuspage polls as fallback.
  var providerStatus: [ProviderID: ProviderStatusReading] = [:]
  /// How often the foreground app polls official status pages. The helper uses the same interval.
  static let providerStatusInterval: TimeInterval = 600
  @ObservationIgnored
  private var providerStatusTimer: Timer?
  @ObservationIgnored
  private var sceneObservers: [any NSObjectProtocol] = []
  @ObservationIgnored
  private var providerStatusTask: Task<Void, Never>?
  @ObservationIgnored
  private var uploadTask: Task<Void, Never>?
  /// The Macs this phone has asked for a fresh reading and is waiting on, while it waits
  /// ([ADR 0063](../../../docs/decisions/0063-collection-follows-demand-and-activity.md)).
  private(set) var collectionDemand: CollectionDemand?
  /// The one request-and-follow-up in flight. Backgrounding and signing out cancel it.
  @ObservationIgnored
  private var demandTask: Task<Void, Never>?
  /// Whether the app is in front of someone. Only then is anyone looking to ask on behalf of.
  @ObservationIgnored
  private var isForeground = false
  @ObservationIgnored private var firstReadingSignaled = false
  #if DEBUG
    @ObservationIgnored private var firstContentSignaled = false
    @ObservationIgnored private var firstContentWaiter: CheckedContinuation<Void, Never>?
  #endif

  #if DEBUG
    /// When true, `QuotaApp` skips `restore()` so visual fixtures stay offline and deterministic.
    var skipsRestore = false
    /// A visual fixture that holds the launch mark still at this much of its draw-in.
    var posedLaunchProgress: Double?
    /// True when this model was built with blocked network and memory stores (a visual scenario).
    private(set) var isOfflineFixture = false
    /// True when `now` is a frozen instant (visual fixtures), not the wall clock.
    private(set) var displayClockIsFixed = false
  #endif

  /// The instant owners and views treat as "now". Fixtures inject a fixed clock.
  var displayClock: DisplayClock {
    #if DEBUG
      DisplayClock(now: now, isFixed: displayClockIsFixed)
    #else
      DisplayClock(now: now, isFixed: false)
    #endif
  }
  var displayNow: Date { now() }

  init(
    account: AccountClient,
    authenticator: any BrowserSessionAuthenticating,
    widgetPublisher: any WidgetSnapshotPublishing = NoOpWidgetSnapshotPublisher(),
    selectionSaltStore: any SelectionSaltStore = InMemorySelectionSaltStore(),
    backgroundRefresh: any BackgroundRefreshScheduling = NoOpBackgroundRefreshScheduler(),
    alertCoordinator: AlertCoordinator? = nil,
    alertRulesStore: AlertRulesStore? = nil,
    alertStateStore: (any AlertStateStore)? = nil,
    notificationCenter: (any NotificationCentering)? = nil,
    makeAuthorizationAttempt: @escaping @Sendable () throws -> AuthorizationAttempt = {
      try AuthorizationRequest.make()
    },
    activity: (any ActivityLoading)? = nil,
    providerSessions: any ProviderSessionStoring = KeychainProviderSessionStore(),
    localStore: any LocalCollectionStoring = MemoryLocalCollectionStore(),
    sampleStore: any LocalQuotaSampleStoring = MemoryLocalQuotaSampleStore(),
    historyWatermarks: any QuotaHistoryWatermarkStoring = MemoryQuotaHistoryWatermarkStore(),
    historyReads: any QuotaHistoryReadStoring = MemoryQuotaHistoryReadStore(),
    localCollector: LocalCollector? = nil,
    providerStatusClient: any ProviderStatusServing = IdleProviderStatusClient(),
    budgetStore: UsageBudgetStore = UsageBudgetStore(),
    settingsDefaults: UserDefaults = .standard,
    syncAccountSettings: Bool = false,
    installation: any InstallationIdentifying = KeychainInstallationIdentity(),
    now: @escaping @Sendable () -> Date = { Date() },
    demandSleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) {
    self.installation = installation
    self.demandSleep = demandSleep
    self.providers = ProvidersModel(store: providerSessions)
    self.localStore = localStore
    self.sampleStore = sampleStore
    self.localCollector =
      localCollector ?? LocalCollector(sessions: providerSessions, now: now)
    self.account = account
    self.authenticator = authenticator
    self.widgetPublisher = widgetPublisher
    self.selectionSaltStore = selectionSaltStore
    self.backgroundRefresh = backgroundRefresh
    self.now = now
    self.makeAuthorizationAttempt = makeAuthorizationAttempt
    let center = notificationCenter ?? NoOpNotificationCenter()
    let sink = UserNotificationAlertSink(center: center)
    self.resetScheduler = ResetReminderScheduler(center: center)
    let resolvedRules = alertRulesStore ?? AlertCoordinator.rulesStore()
    if let alertCoordinator {
      self.alertCoordinator = alertCoordinator
      self.userNotificationSink = nil
    } else {
      self.userNotificationSink = sink
      self.alertCoordinator = AlertCoordinator(
        rulesStore: resolvedRules,
        stateStore: alertStateStore ?? InMemoryAlertStateStore(),
        budgetStore: budgetStore,
        sink: sink,
        now: now
      )
    }
    self.providerStatusClient = providerStatusClient
    let usage = UsageModel(
      activity: activity ?? AccountClientActivityLoading(client: account),
      budgetStore: budgetStore,
      now: now
    )
    self.usage = usage
    let accountSettings = AccountSettingsSync(
      account: account,
      rulesStore: resolvedRules,
      budgetStore: budgetStore,
      defaults: settingsDefaults,
      connectsToAccount: syncAccountSettings
    )
    self.accountSettings = accountSettings
    let quotaHistory = QuotaHistoryCoordinator(
      account: account,
      watermarks: historyWatermarks,
      reads: historyReads,
      now: now
    )
    self.quotaHistory = quotaHistory
    quotaHistory.historySync = { [weak accountSettings] in
      guard let accountSettings else { return nil }
      return accountSettings.historySync
    }
    quotaHistory.noteSyncOff = { [weak accountSettings] in accountSettings?.noteHistorySyncOff() }
    quotaHistory.localSamples = { [weak self] in self?.localSamples ?? LocalQuotaSamples() }
    quotaHistory.snapshots = { [weak self] in self?.localCollection?.snapshots ?? [] }
    accountSettings.onHistoryEdited = { [weak quotaHistory] in
      await quotaHistory?.sync()
    }
    usage.isSignedIn = { [weak self] in self?.phase == .signedIn }
    usage.sessionEpoch = { [weak self] in self?.accountSessionEpoch ?? 0 }
    usage.onSessionExpired = { [weak self] in self?.applyExpired() }
    usage.onNotSignedIn = { [weak self] in self?.applySignedOut() }
    usage.evaluateBudget = { [weak self] budget, progress in
      self?.alertCoordinator.evaluateBudget(budget: budget, progress: progress)
    }
    usage.onBudgetEdited = { [weak accountSettings] budget in
      Task { await accountSettings?.apply(.setBudget(amount: budget.amountUSD, alerts: budget.alerts)) }
    }
    accountSettings.isSignedIn = { [weak self] in self?.phase == .signedIn }
    accountSettings.onApplied = { [weak self] in
      self?.usage.reloadBudgetFromStore()
      self?.evaluateAlerts()
      self?.usage.evaluateBudgetAlerts()
    }
    #if DEBUG
      usage.skipsUnforcedLoad = { [weak self] in self?.skipsRestore ?? false }
    #endif
  }

  convenience init(backgroundRefresh: any BackgroundRefreshScheduling) {
    let relay = RelayClient()
    self.init(
      account: AccountClient(
        relay: relay,
        sessionStore: KeychainAccountSessionStore(),
        summaryStore: (try? ProtectedFileAccountSummaryStore.applicationSupport())
          ?? MemoryAccountSummaryStore(),
        settingsStore: (try? ProtectedFileAccountSettingsStore.applicationSupport())
          ?? MemoryAccountSettingsStore(),
        usageStore: (try? ProtectedFileAccountUsageStore.applicationSupport())
          ?? MemoryAccountUsageStore()
      ),
      authenticator: SystemBrowserAuthenticator(),
      widgetPublisher: AppGroupWidgetSnapshotPublisher.make(),
      selectionSaltStore: KeychainSelectionSaltStore(),
      backgroundRefresh: backgroundRefresh,
      alertStateStore: FileAlertStateStore(
        fileURL: AlertCoordinator.stateFileURL(
          applicationSupport: FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        )
      ),
      notificationCenter: SystemNotificationCenter(),
      localStore: FileLocalCollectionStore.applicationSupport() ?? MemoryLocalCollectionStore(),
      sampleStore: FileLocalQuotaSampleStore.applicationSupport()
        ?? MemoryLocalQuotaSampleStore(),
      historyWatermarks: FileQuotaHistoryWatermarkStore.applicationSupport()
        ?? MemoryQuotaHistoryWatermarkStore(),
      historyReads: FileQuotaHistoryReadStore.applicationSupport()
        ?? MemoryQuotaHistoryReadStore(),
      providerStatusClient: ProviderStatusClient(
        catalog: RelayProviderStatusCatalog(relay: relay),
        store: try? ProtectedFileProviderStatusStore.applicationSupport()
      ),
      syncAccountSettings: true
    )
  }

  /// Cached Account summary or local readings the Overview can already show.
  var hasContent: Bool {
    summary != nil || !subscriptions.isEmpty
  }

  /// How many placeholder cards Overview draws instead of the empty state: nothing has ever been
  /// read on this phone, and the first answer is on its way. One per provider session, or two
  /// when the Account is the only source. The empty state waits for a refresh that answered empty.
  var overviewPlaceholders: Int {
    guard summary == nil, localCollection == nil else { return 0 }
    guard phase == .launching || isRefreshing || awaitsFirstRefresh else { return 0 }
    if !providers.sessions.isEmpty { return providers.sessions.count }
    return hasAccountSession ? 2 : 0
  }

  /// How far this refresh has come, once more than one read is in flight and one has answered.
  var refreshProgress: (answered: Int, total: Int)? {
    guard isRefreshing, refreshReads > 1 else { return nil }
    let answered = refreshReads - pendingReadings.count - (awaitsSummary ? 1 : 0)
    guard answered > 0 else { return nil }
    return (answered, refreshReads)
  }

  /// Whether a row's reading has yet to arrive in the refresh that is running: its provider
  /// session has not answered, or it is the Account's alone and the summary has not.
  func isAwaitingReading(_ subscription: QuotaSubscription) -> Bool {
    guard isRefreshing else { return false }
    if pendingReadings.contains(LocalCollector.sessionKey(for: subscription.snapshot)) {
      return true
    }
    return awaitsSummary && !subscription.sources.contains { $0.deviceID == ThisDevice.sourceID }
  }

  /// What this phone presents when it signs in, so its session names a Device and what it reads
  /// can reach the Macs ([ADR 0041](../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)).
  private var deviceRegistration: IosDeviceRegistration? {
    ThisIPhone.registration(identity: installation)
  }

  /// The Overview title. Without an account there is no label to print, and the app is still
  /// showing quota, so it says what it is showing.
  var accountLabel: String {
    PlanDisplay.accountLabel(summary?.account.displayLabel)
      ?? (summary == nil ? "Quota" : "Account")
  }

  /// When the readings on screen were last refreshed, from either side of the merge.
  var updatedAt: Date? {
    [fetchedAt, localCollection?.collectedAt].compactMap { $0 }.max()
  }

  /// Whether a session for the managed Account exists on this device, whatever state it is in.
  var hasAccountSession: Bool { sessionActivation != nil }

  /// About shows the history switch only for an active session. Pending still hides it.
  var showsShareQuotaHistory: Bool { sessionActivation == .active }

  /// Whether the Account already lists this phone as one of its Devices. It does once the
  /// session that named it has been read back in a summary, and Devices then shows that row
  /// rather than the one this phone would draw for itself.
  var isRegisteredDevice: Bool {
    guard let sessionDeviceID else { return false }
    return summary?.devices.contains { $0.id == sessionDeviceID } ?? false
  }

  /// The subscriptions this app shows: what this iPhone read for itself, merged with what Relay
  /// resolved from every Mac. One rule, stated in `QuotaObservations` and judged by
  /// `quota-observation-conformance.json`.
  var subscriptions: [QuotaSubscription] {
    LocalObservationMerge.subscriptions(
      local: localCollection?.snapshots ?? [],
      resolved: summary?.subscriptions ?? [],
      selfDeviceID: sessionDeviceID,
      now: now()
    )
  }

  /// Which sides of the merge answered. Overview says nothing different for a merged row, but
  /// the surfaces around it do: Today needs an account, and the empty state needs to know which
  /// invitation it is short of.
  var overviewSources: OverviewSources {
    OverviewSources(
      hasLocal: !(localCollection?.snapshots ?? []).isEmpty,
      hasAccount: summary != nil
    )
  }

  /// One group per provider, and inside it one Overview row per subscription rather than per
  /// reporting device: an account collected on three Macs is one subscription, not three,
  /// and Relay has already resolved it that way.
  var providerCards: [ProviderQuotaCardModel] {
    let grouped = Dictionary(grouping: subscriptions) { $0.snapshot.provider }
    return ProviderID.allCases.compactMap { provider in
      guard let subscriptions = grouped[provider], !subscriptions.isEmpty else { return nil }
      return ProviderQuotaCardModel(provider: provider, subscriptions: subscriptions)
    }
  }

  /// The app's launch: what is on disk first, then the first refresh beside the foreground work.
  /// Neither waits for the other — Usage and the status pages do not need this phone's providers
  /// to have answered, and the Overview is already showing the cache.
  func launch() async {
    await restoreLocalState()
    async let first: Void = refreshAfterRestore()
    async let foreground: Void = setForeground(true)
    observeApplicationLifecycle()
    _ = await (first, foreground)
    demandCollectionIfStale()
  }

  /// Restore the local state, then run the first refresh it calls for.
  func restore() async {
    await restoreLocalState()
    await refreshAfterRestore()
  }

  /// Everything this phone already knows, read from disk and Keychain: the first content. It asks
  /// nothing of the network.
  private func restoreLocalState() async {
    let restoreInterval = LaunchSignposts.begin("restore")
    defer { LaunchSignposts.end("restore", restoreInterval) }
    let localStore = self.localStore
    let sampleStore = self.sampleStore
    let loaded = await Task.detached(priority: .userInitiated) {
      (
        try? localStore.load(),
        (try? sampleStore.load()) ?? LocalQuotaSamples()
      )
    }.value
    localCollection = loaded.0
    localSamples = loaded.1
    providers.markNeedsSignIn(localCollection?.needsSignIn ?? [])
    let persistedStatus = await providerStatusClient.persistedReadings()
    if !persistedStatus.isEmpty {
      providerStatus = Dictionary(
        uniqueKeysWithValues: persistedStatus.map { ($0.provider, $0) })
    }
    let restored: RestoredAccountState
    do {
      restored = try await account.restoreLocalState()
    } catch AccountStoreError.unreadable {
      restored = RestoredAccountState(session: nil, summary: nil, usage: nil)
    } catch {
      restored = RestoredAccountState(session: nil, summary: nil, usage: nil)
    }
    sessionActivation = restored.session?.activation
    sessionDeviceID = restored.session?.deviceID
    await accountSettings.seedHistorySyncFromCache()
    summary = restored.summary?.summary
    fetchedAt = restored.summary?.fetchedAt
    summaryETag = restored.summary?.etag
    usage.accountSummaryAccepted(restored.summary?.summary, etag: restored.summary?.etag)
    if let usage = restored.usage {
      self.usage.applyDiskCache(usage)
    }
    fromCache = restored.summary != nil
    switch restored.session?.activation {
    case .active:
      phase = .signedIn
      awaitsFirstRefresh = true
      // Publish what was already on disk so the widget is current before the network is.
      if restored.summary != nil { publishWidget() }
      resolvePendingSubscriptionSelection()
    case .pending:
      if let label = PlanDisplay.accountLabel(restored.summary?.summary.account.displayLabel) {
        phase = .confirmingAccount(label: label)
      } else {
        awaitsFirstRefresh = true
      }
    case nil:
      // Signed out is not empty any more: the providers this phone signed in to are still
      // readable, and the last reading of them is already loaded. The first refresh publishes
      // what that comes to; the widget keeps the previous snapshot until it does.
      phase = .signedOut
      awaitsFirstRefresh = !providers.sessions.isEmpty
      resolvePendingSubscriptionSelection()
    }
    hasRestoredLocalState = true
    LaunchSignposts.event("first-content")
    #if DEBUG
      signalFirstContent()
    #endif
  }

  /// The refresh restore calls for. A pending session with no label is still waiting to be told
  /// which Account it reached, so its refresh is the identifying read.
  private func refreshAfterRestore() async {
    switch sessionActivation {
    case .active:
      await refresh(awaitUpload: false)
    case .pending:
      guard phase == .launching else { return }
      await refresh()
      if phase == .launching {
        presentPendingRefreshFailure(message: AuthorizationError.genericConnectFailureMessage)
      }
    case nil:
      await refresh(awaitUpload: false)
    }
    LaunchSignposts.event("fresh-content")
  }

  /// Open the one page that offers every way in. Nothing is started until a way is chosen.
  func showSignIn() {
    guard phase == .signedOut || phase == .signedIn else { return }
    banner = nil
    expiredMessage = nil
    presentsSignIn = true
  }

  /// Sign in through the browser: the Relay authorize URL, which asks which Account this is and
  /// offers every channel that reaches one.
  ///
  /// Two ends can answer it. GitHub and the confirm page come back inside
  /// `ASWebAuthenticationSession`; an emailed link is opened in the system browser instead, and
  /// its authorization callback reaches `openDeepLink`. Whichever answers first takes
  /// `pendingWebSignIn`, and the other finds it gone and stands down.
  func connectAccount(switchingAccount: Bool = false) async {
    if !switchingAccount {
      guard phase != .connecting else { return }
    }
    presentsSignIn = false
    phase = .connecting
    banner = nil
    expiredMessage = nil
    do {
      let attempt = try makeAuthorizationAttempt()
      pendingWebSignIn = attempt
      let callback = try await authenticator.authenticate(
        url: attempt.authorizationURL,
        callbackScheme: QuotaIOSOAuth.callbackScheme,
        prefersEphemeralWebBrowserSession: switchingAccount
      )
      guard pendingWebSignIn != nil else { return }
      pendingWebSignIn = nil
      try await keepSession(callback: callback, expected: attempt)
    } catch is CancellationError {
      pendingWebSignIn = nil
      applySignedOut()
    } catch AuthorizationError.cancelled, AccountClientError.cancelled {
      // Cancel is also how the sheet ends when the emailed link was answered outside it, and
      // that completion has already taken the attempt.
      guard pendingWebSignIn != nil else { return }
      pendingWebSignIn = nil
      applySignedOut()
    } catch {
      pendingWebSignIn = nil
      applyConnectFailure(error)
    }
  }

  /// Finish the browser round trip an emailed sign-in link completed in the system browser.
  ///
  /// The link is opened by the mail app, so the verifying navigation never passes through the
  /// authentication session; Relay's redirect to the app is what comes back. The sheet is still
  /// waiting on a callback it will never see, so it is ended here.
  private func completeEmailedSignIn(_ callback: URL) async {
    guard let attempt = pendingWebSignIn else {
      // Nothing here started this round trip — the app has been relaunched since — so there is
      // no verifier left to spend the code with.
      presentConnectFailure(AuthorizationError.genericConnectFailureMessage)
      return
    }
    pendingWebSignIn = nil
    authenticator.cancelPresentation()
    do {
      try await keepSession(callback: callback, expected: attempt)
    } catch {
      applyConnectFailure(error)
    }
  }

  private func keepSession(callback: URL, expected: AuthorizationAttempt) async throws {
    let session = try await account.completeLogin(
      callback: callback,
      expected: expected,
      device: deviceRegistration
    )
    apply(session)
    expiredMessage = nil
    banner = nil
    await refresh()
  }

  /// What a sign-in failure leaves on screen. Both ends of the round trip answer it the same way.
  private func applyConnectFailure(_ error: any Error) {
    if let error = error as? AccountClientError {
      if error == .sessionExpired {
        applyExpired()
      } else {
        presentConnectFailure(error.userFacingMessage)
      }
      return
    }
    if let error = error as? AuthorizationError {
      presentConnectFailure(error.userFacingMessage)
      return
    }
    presentConnectFailure(AuthorizationError.genericConnectFailureMessage)
  }

  /// Bind the Sign in with Apple request the button is about to make.
  ///
  /// Apple is handed the nonce's digest and states it back inside the token it signs; this device
  /// keeps the value, so a token minted for some earlier request proves nothing about this one.
  /// An address is asked for because it is what names the channel on the Account, and Apple hands
  /// it over only while the person is sharing one.
  func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
    request.requestedScopes = [.fullName, .email]
    let nonce = try? AppleSignIn.generateNonce()
    appleNonce = nonce
    request.nonce = nonce?.digest
  }

  /// Sign in with what Apple proved on this device.
  ///
  /// There is no browser round trip: `ASAuthorizationAppleIDProvider` has already asked the
  /// question, so the token it signed goes straight to Relay, and what comes back is the same
  /// pending session a browser sign-in opens — the confirm screen still asks which Account this
  /// reached.
  func connectWithApple(_ result: Result<ASAuthorization, any Error>) async {
    guard phase != .connecting else { return }
    guard let nonce = appleNonce else {
      presentConnectFailure(AuthorizationError.genericConnectFailureMessage)
      return
    }
    appleNonce = nil
    switch result {
    case .failure(let error):
      // Cancel is not a failure: the person closed the sheet and is where they started.
      if (error as? ASAuthorizationError)?.code == .canceled {
        applySignedOut()
      } else {
        presentConnectFailure(AuthorizationError.genericConnectFailureMessage)
      }
    case .success(let authorization):
      guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
        let data = credential.identityToken,
        let identityToken = String(data: data, encoding: .utf8)
      else {
        presentConnectFailure(AuthorizationError.unexpectedBrowserResponseMessage)
        return
      }
      await exchangeApple(identityToken: identityToken, nonce: nonce.value)
    }
  }

  private func exchangeApple(identityToken: String, nonce: String) async {
    presentsSignIn = false
    phase = .connecting
    banner = nil
    expiredMessage = nil
    do {
      let session = try await account.exchangeApple(
        identityToken: identityToken,
        nonce: nonce,
        device: deviceRegistration
      )
      apply(session)
      await refresh()
    } catch AccountClientError.sessionExpired {
      applyExpired()
    } catch let error as AccountClientError {
      presentConnectFailure(error.userFacingMessage)
    } catch {
      presentConnectFailure(AuthorizationError.genericConnectFailureMessage)
    }
  }

  /// Keep what a sign-in answered: how far along the session is, and the Device it speaks for.
  private func apply(_ session: AccountSession) {
    sessionActivation = session.activation
    sessionDeviceID = session.deviceID
  }

  private func forgetSession() {
    sessionActivation = nil
    sessionDeviceID = nil
    accountSettings.noteSignedOut()
  }

  private func presentConnectFailure(_ message: String) {
    applySignedOut()
    banner = Banner(kind: .refreshFailed, text: message, symbolName: "exclamationmark.triangle")
  }

  /// Keep the session this device just opened. Continue is the only promotion to `active`.
  func confirmAccount() async {
    guard case .confirmingAccount = phase else { return }
    do {
      try await account.activateSession()
    } catch {
      banner = Banner(
        kind: .refreshFailed,
        text: AuthorizationError.genericConnectFailureMessage,
        symbolName: "exclamationmark.triangle"
      )
      return
    }
    sessionActivation = .active
    expiredMessage = nil
    phase = .signedIn
    if summary != nil, fetchedAt != nil {
      banner = nil
    } else {
      banner = failureBanner(hasCachedSummary: false, offline: false)
    }
    publishWidget()
    evaluateAlerts()
    await accountSettings.refresh()
    scheduleBackgroundRefresh()
    resolvePendingSubscriptionSelection()
    pruneOverviewPath()
  }

  /// Retry the identifying Account read while the session stays pending.
  func retryPendingIdentification() async {
    guard phase == .pendingRefreshFailed else { return }
    banner = nil
    expiredMessage = nil
    await refresh()
  }

  /// Revoke the session just opened and sign in again in an ephemeral browser session so GitHub
  /// cannot reuse the Safari account.
  func useDifferentAccount() async {
    switch phase {
    case .confirmingAccount, .pendingRefreshFailed: break
    default: return
    }
    phase = .connecting
    banner = nil
    expiredMessage = nil
    await account.logout()
    forgetSession()
    summary = nil
    fetchedAt = nil
    summaryETag = nil
    usage.accountSummaryAccepted(nil, etag: nil)
    fromCache = false
    clearWidget()
    await connectAccount(switchingAccount: true)
  }

  /// The one refresh the pull-to-refresh gesture, the refresh button and a background app refresh
  /// all run: read the providers this phone signed in to and, when there is an account, the
  /// account summary — at the same time, because neither waits on the other.
  ///
  /// Each side reaches the screen the moment it answers: the summary is applied when it arrives,
  /// and every provider reading is merged into the local collection as it comes back, so one slow
  /// provider holds up nothing but its own row. What the whole pass came to is then handled once:
  /// the local readings are kept on disk and sampled, the widget snapshot is republished, local
  /// remaining-quota alerts and reset reminders are evaluated, what this phone read is uploaded,
  /// and the next background window is asked for. Reports whether either side answered, which is
  /// the success a `BGAppRefreshTask` completes with.
  ///
  /// One refresh runs at a time; a second request while one is running is refused. The next
  /// window is only worth asking for while something is left to read. A phone with neither an
  /// account nor a provider session withdraws the standing ask on its way out.
  @discardableResult
  func refresh(
    budget: Duration = LocalCollector.foregroundBudget,
    awaitUpload: Bool = true,
    manual: Bool = false
  ) async -> Bool {
    guard !isRefreshing else { return false }
    isRefreshing = true
    let asked = providers.sessions.map(\.key)
    pendingReadings = Set(asked)
    refreshReads = pendingReadings.count
    defer {
      isRefreshing = false
      awaitsFirstRefresh = false
      pendingReadings = []
      awaitsSummary = false
      refreshReads = 0
    }
    kickProviderStatus()
    let collector = localCollector
    let previous = localCollection
    let localInterval = LaunchSignposts.begin("local-collection")
    async let collected: LocalCollector.Pass? =
      asked.isEmpty
      ? nil
      : collector.collect(within: budget, manual: manual) { [weak self] answer in
        await self?.accept(answer)
      }
    // The session is read from its store rather than from what a previous read left in memory: a
    // background refresh can run before anything has restored. An unreadable Keychain is not a
    // sign-out: the phone may be locked.
    let presence = await account.sessionPresence()
    var result: AccountRefreshResult?
    var summaryFollowUp = SummaryFollowUp.none
    if case .signedIn = presence {
      awaitsSummary = true
      refreshReads += 1
      let summaryInterval = LaunchSignposts.begin("summary")
      let answered = await account.fetchTodaySummary()
      LaunchSignposts.end("summary", summaryInterval)
      awaitsSummary = false
      result = answered
      summaryFollowUp = await apply(answered)
    }
    let pass = await collected
    LaunchSignposts.end("local-collection", localInterval)
    if let pass { finishLocalPass(pass, previous: previous) }
    // A pass cut at its budget still read something if any provider answered in time.
    let readLocally = pass.map { $0.isComplete || !$0.collection.snapshots.isEmpty } ?? false
    switch presence {
    case .signedIn:
      if result != nil {
        switch summaryFollowUp {
        case .publish:
          publishWidget()
          evaluateAlerts()
        case .afterFailure(let hasTrustedSummary):
          syncWidgetAfterFailure(hasTrustedSummary: hasTrustedSummary, collected: readLocally)
        case .none:
          break
        }
        await finishUpload(pass?.collection, wait: awaitUpload)
        scheduleBackgroundRefresh()
      }
    case .signedOut:
      applyWithoutAccount()
    case .unknown:
      if readLocally {
        if summary != nil {
          publishWidget()
        }
        evaluateAlerts()
      }
    }
    // `result?.error == nil` would answer true for a refresh that never read at all, so what
    // each side actually answered is asked separately.
    return (result.map { $0.error == nil } ?? false) || readLocally
  }

  /// What is left to do with a summary once the local pass beside it has finished.
  private enum SummaryFollowUp {
    case none
    case publish
    case afterFailure(hasTrustedSummary: Bool)
  }

  /// One provider answered: its reading replaces the one on screen for the same account, now.
  /// Keeping it, sampling it and marking refused sessions wait for the end of the pass.
  private func accept(_ answer: LocalCollector.Answer) {
    guard isRefreshing else { return }
    pendingReadings.remove(answer.sessionKey)
    guard case .reading(let snapshot) = answer.kind else { return }
    var collection = localCollection ?? LocalCollection(collectedAt: now())
    collection.snapshots.removeAll {
      LocalCollector.sessionKey(for: $0) == LocalCollector.sessionKey(for: snapshot)
    }
    collection.snapshots.append(snapshot)
    collection.snapshots.sort { $0.account.fingerprint < $1.account.fingerprint }
    localCollection = collection
    if !firstReadingSignaled {
      firstReadingSignaled = true
      LaunchSignposts.event("first-reading")
    }
  }

  /// What the pass came to. A complete pass is the whole answer, except for a provider that
  /// asked to be left alone: rate limited or still backed off, it keeps the reading it had. A pass
  /// cut at its budget keeps every reading that arrived, and for a session that did not answer in
  /// time, the reading it had before — a phone woken briefly shows the last quota it knows, not
  /// none.
  private func finishLocalPass(_ pass: LocalCollector.Pass, previous: LocalCollection?) {
    var collection = pass.collection
    let answered = Set(
      collection.snapshots.map(LocalCollector.sessionKey(for:)) + collection.needsSignIn)
    var kept = Set(pass.heldSessionKeys)
    if !pass.isComplete {
      kept.formUnion(Set(pass.sessionKeys).subtracting(answered))
    }
    guard !kept.isEmpty else {
      applyLocalCollection(collection)
      return
    }
    collection.snapshots += (previous?.snapshots ?? []).filter {
      kept.contains(LocalCollector.sessionKey(for: $0))
    }
    collection.snapshots.sort { $0.account.fingerprint < $1.account.fingerprint }
    collection.needsSignIn += (previous?.needsSignIn ?? []).filter(kept.contains)
    collection.needsSignIn.sort()
    applyLocalCollection(collection)
  }

  func waitForDetachedLaunchWork() async {
    await providerStatusTask?.value
    await uploadTask?.value
  }

  /// One upload at a time. The launch path detaches; background refresh awaits so
  /// `BGAppRefreshTask` does not complete before the Device write (ADR 0041).
  ///
  /// The chain is `Task.detached`, not `Task { @MainActor }`: a MainActor task cannot start
  /// while `refresh()` still holds the main actor, so a second refresh would run beside it
  /// and two `GET /device/sync` would overlap.
  private func finishUpload(_ collection: LocalCollection?, wait: Bool) async {
    let previous = uploadTask
    let snapshots = collection
    let task = Task.detached { [weak self] in
      await previous?.value
      await self?.uploadLocalReadings(snapshots)
    }
    uploadTask = task
    if wait {
      // A detached task does not inherit cancellation, and the background path's expiration
      // handler has to reach the upload it is waiting on.
      await withTaskCancellationHandler {
        await task.value
      } onCancel: {
        task.cancel()
      }
    }
  }

  /// A provider sign-in was kept or removed. What this phone can read changed, so the readings
  /// on screen and the standing background ask both follow it.
  func providerSessionsChanged() async {
    updateBackgroundRefreshAsk()
    await refresh()
  }

  /// Send what this phone just read to the Account, when it is a Device, then the quota-history
  /// buckets while the Account switch is on.
  ///
  /// Only the readings go: the provider sessions behind them stay in this device's Keychain, and
  /// Usage is a Mac's, because this phone has none
  /// ([ADR 0041](../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)).
  /// The history upload is awaited here, the same way the snapshot upload is, so a background
  /// refresh does not finish while either write is still in flight.
  private func uploadLocalReadings(_ collection: LocalCollection?) async {
    // A background wake can run `refresh` before `restore` has copied the session into memory.
    if sessionActivation == nil, let session = try? await account.loadSession() {
      sessionActivation = session.activation
      sessionDeviceID = session.deviceID
    }
    guard sessionDeviceID != nil, sessionActivation == .active else { return }
    let uploadInterval = LaunchSignposts.begin("upload")
    defer { LaunchSignposts.end("upload", uploadInterval) }
    if let collection, !collection.snapshots.isEmpty {
      if let error = await account.uploadSnapshots(collection.snapshots),
        error == .sessionExpired
      {
        applyExpired()
        return
      }
    }
    // Same task the background refresh awaits for the snapshot upload (ADR 0041).
    await accountSettings.seedHistorySyncFromCache()
    await quotaHistory.sync()
  }

  /// The detail chart's Account series, when the switch is on. A miss is today's local chart.
  func loadAccountQuotaHistory(for subscription: QuotaSubscription) async {
    await quotaHistory.load(subscription)
  }

  /// Keep what this pass read, and let Settings say which sessions the provider refused.
  private func applyLocalCollection(_ collection: LocalCollection) {
    localCollection = collection
    try? localStore.save(collection)
    localSamples.record(collection.snapshots, now: now())
    try? sampleStore.save(localSamples)
    // A successful read moves `lastValidatedAt` in the Keychain, so the rows are re-read.
    providers.load()
    providers.markNeedsSignIn(collection.needsSignIn)
  }

  /// A refresh with no account to read. What this iPhone collected is the whole answer, and the
  /// widget and the alert rules are evaluated against it just the same.
  private func applyWithoutAccount() {
    phase = .signedOut
    publishWidget()
    evaluateAlerts()
    resolvePendingSubscriptionSelection()
    pruneOverviewPath()
    updateBackgroundRefreshAsk()
  }

  /// Start or stop the ten-minute status-page timer with the scene. A background refresh still
  /// polls through `refresh()`; this is the independent foreground cadence.
  func setForeground(_ isForeground: Bool) async {
    self.isForeground = isForeground
    if !isForeground {
      stopCollectionDemand()
    }
    if isForeground {
      await startProviderStatusPolling()
      async let activity: Void = usage.loadActivity(force: true)
      async let period: Void = usage.loadPeriod(force: true)
      async let budget: Void = usage.loadBudgetPeriod(force: true)
      async let rhythm: Void = usage.loadRhythm(force: true)
      _ = await (activity, period, budget, rhythm)
    } else {
      stopProviderStatusPolling()
    }
  }

  /// Follow the app into the background and back. Visual fixtures never call this, so they
  /// stay offline and do not observe the scene.
  func observeApplicationLifecycle() {
    #if DEBUG
      if skipsRestore { return }
    #endif
    guard sceneObservers.isEmpty else { return }
    let center = NotificationCenter.default
    sceneObservers.append(
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          await self?.setForeground(false)
        }
      }
    )
    sceneObservers.append(
      center.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          await self?.returnedToForeground()
        }
      }
    )
    sceneObservers.append(
      center.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          await self?.setForeground(true)
        }
      }
    )
  }

  func refreshProviderStatus() async {
    #if DEBUG
      if skipsRestore { return }
    #endif
    let statusInterval = LaunchSignposts.begin("status")
    defer { LaunchSignposts.end("status", statusInterval) }
    let readings = await providerStatusClient.refresh()
    providerStatus = Dictionary(uniqueKeysWithValues: readings.map { ($0.provider, $0) })
  }

  private func kickProviderStatus() {
    #if DEBUG
      if skipsRestore { return }
    #endif
    guard providerStatusTask == nil else { return }
    providerStatusTask = Task { [weak self] in
      await self?.refreshProviderStatus()
      await MainActor.run {
        self?.providerStatusTask = nil
      }
    }
  }

  private func startProviderStatusPolling() async {
    #if DEBUG
      if skipsRestore { return }
    #endif
    guard providerStatusTimer == nil else { return }
    if providerStatusTask == nil {
      kickProviderStatus()
    }
    let timer = Timer(timeInterval: Self.providerStatusInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.kickProviderStatus()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    providerStatusTimer = timer
  }

  private func stopProviderStatusPolling() {
    providerStatusTimer?.invalidate()
    providerStatusTimer = nil
  }

  func logout() async {
    await account.logout()
    applySignedOut()
  }

  /// Pull to refresh and the refresh button: read everything this phone reads, then ask the
  /// Account's Macs when what they last sent is old. A provider this phone backed off from may
  /// be asked anyway, once a minute.
  func refreshOnRequest() async {
    await refresh(manual: true)
    demandCollectionIfStale()
  }

  /// Back from the background: read the summary, and ask the Macs when what it shows is old.
  func returnedToForeground() async {
    isForeground = true
    guard phase == .signedIn, !isRefreshing, demandTask == nil else { return }
    await readSummaryForDemand()
    demandCollectionIfStale()
  }

  /// Ask the Account's Macs for a fresh reading when a Mac's reading on screen is more than two
  /// minutes old, then follow the summary until they answer, the app leaves the foreground, or
  /// three minutes pass. A Relay that refuses — one that predates the request, or a session that
  /// asked too often — is not an error anyone sees: the readings stay as they are.
  func demandCollectionIfStale() {
    #if DEBUG
      if skipsRestore { return }
    #endif
    guard isForeground, phase == .signedIn, sessionActivation == .active, demandTask == nil,
      let summary,
      let demand = CollectionDemand.stale(in: summary, selfDeviceID: sessionDeviceID, now: now())
    else { return }
    demandTask = Task { [weak self] in
      await self?.followUp(demand)
    }
  }

  private func followUp(_ asked: CollectionDemand) async {
    defer {
      if !Task.isCancelled {
        demandTask = nil
        collectionDemand = nil
      }
    }
    guard let requestedAt = await account.requestCollection(), !Task.isCancelled else { return }
    var demand = asked
    demand.requestedAt = requestedAt
    collectionDemand = demand
    for _ in 0..<CollectionDemand.followUpReads {
      do {
        try await demandSleep(CollectionDemand.followUpInterval)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      if !isRefreshing {
        await readSummaryForDemand()
      }
      guard !Task.isCancelled, phase == .signedIn, let summary else { return }
      if demand.isAnswered(by: summary, selfDeviceID: sessionDeviceID) { return }
    }
  }

  private func stopCollectionDemand() {
    demandTask?.cancel()
    demandTask = nil
    collectionDemand = nil
  }

  /// The Macs being waited on, when the subtitle should say so.
  var askingMacs: Int? {
    guard let collectionDemand, collectionDemand.requestedAt != nil else { return nil }
    return collectionDemand.macCount
  }

  /// One conditional summary read and nothing else: the providers this phone reads for itself
  /// are not what a Mac is being waited on for. An unchanged answer changes nothing on screen.
  private func readSummaryForDemand() async {
    let result = await account.fetchTodaySummary()
    if result.error == nil, result.etag != nil, result.etag == summaryETag, summary != nil {
      fetchedAt = result.fetchedAt
      return
    }
    switch await apply(result) {
    case .publish:
      publishWidget()
      evaluateAlerts()
    case .afterFailure(let hasTrustedSummary):
      syncWidgetAfterFailure(hasTrustedSummary: hasTrustedSummary, collected: false)
    case .none:
      break
    }
  }

  #if DEBUG
    /// Test seam: wait for the request and its follow-up to finish.
    func waitForCollectionDemand() async {
      await demandTask?.value
    }
  #endif

  /// Read the channels that reach this Account. Settings asks on appearance and after a bind.
  func loadIdentities() async {
    #if DEBUG
      // A visual fixture states what it shows; it opens no network and reads no Keychain.
      if skipsRestore { return }
    #endif
    guard hasAccountSession else {
      identities = .idle
      return
    }
    linkFailure = nil
    if identities.identities.isEmpty { identities = .loading }
    do {
      identities = .loaded(try await account.fetchIdentities())
    } catch {
      identities = .failed
    }
  }

  /// Bind Apple to this Account with what Apple proved on the device.
  ///
  /// The same proof as signing in with Apple, asked for the same way; what makes it a bind is the
  /// session it is sent under
  /// ([ADR 0032](../../../docs/decisions/0032-an-account-owns-its-identities.md)).
  func linkApple(_ result: Result<ASAuthorization, any Error>) async {
    guard let nonce = appleNonce else { return }
    appleNonce = nil
    linkFailure = nil
    guard case .success(let authorization) = result else {
      // Cancel and a refusal at Apple both leave the Account exactly as it was.
      return
    }
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
      let data = credential.identityToken,
      let identityToken = String(data: data, encoding: .utf8)
    else {
      linkFailure = SettingsCopy.linkFailed
      return
    }
    linkingProvider = .apple
    do {
      _ = try await account.linkApple(identityToken: identityToken, nonce: nonce.value)
      linkingProvider = nil
      await loadIdentities()
    } catch AccountClientError.relay(.rejected(_, 409)) {
      linkingProvider = nil
      linkFailure = SettingsCopy.linkTaken
    } catch {
      linkingProvider = nil
      linkFailure = SettingsCopy.linkFailed
    }
  }

  /// Open the website's Sign-in methods, which is where a channel is bound through a browser and
  /// the only place one is unbound.
  ///
  /// Unbinding is a destructive account change the website asks for a recent sign-in before
  /// allowing, so this app sends the person to it rather than holding a second copy of that rule
  /// ([ADR 0032](../../../docs/decisions/0032-an-account-owns-its-identities.md)).
  func presentSignInMethodsOnWeb() async {
    try? await authenticator.present(
      url: QuotaWebLinks.signInMethodsStart,
      callbackScheme: nil,
      prefersEphemeralWebBrowserSession: false
    )
    await loadIdentities()
  }

  /// Opens the website Delete Account flow in `ASWebAuthenticationSession` with shared cookies.
  /// The sheet ending — including cancel — returns here so Settings can prompt to sign out.
  func presentDeleteAccount() async {
    try? await authenticator.present(
      url: QuotaWebLinks.deleteAccountStart,
      callbackScheme: nil,
      prefersEphemeralWebBrowserSession: false
    )
  }

  /// Show the Providers group, which is where a sign-in to a provider starts.
  func showProviders() {
    selectedTab = .settings
  }

  func openDeepLink(_ url: URL) {
    let link = DeepLink.parse(url)
    // A sign-in answering itself is not a place in the app to go to, so it is taken before the
    // tab and the Overview stack are moved.
    if link == .oauthCallback {
      Task { await completeEmailedSignIn(url) }
      return
    }
    selectedTab = .quota
    if case .subscription(let id) = link {
      pendingSubscriptionSelection = id
      resolvePendingSubscriptionSelection()
    } else {
      pendingSubscriptionSelection = nil
      overviewPath = []
    }
  }

  /// When a summary exists, match `pendingSubscriptionSelection` against each subscription's
  /// salted selection id. A hit pushes that row; a miss stays on Overview and clears pending.
  /// No summary yet keeps the pending id so a later restore or refresh can answer it.
  func resolvePendingSubscriptionSelection() {
    guard let pending = pendingSubscriptionSelection else { return }
    let subscriptions = subscriptions
    guard !subscriptions.isEmpty else { return }
    guard let salt = try? selectionSaltStore.loadOrCreate() else { return }
    pendingSubscriptionSelection = nil
    if let match = subscriptions.first(where: {
      WidgetSnapshotProjection.selectionID(for: $0, salt: salt) == pending
    }) {
      overviewPath = [match.key]
    } else {
      overviewPath = []
    }
  }

  func subscription(forKey key: String) -> QuotaSubscription? {
    subscriptions.first { $0.key == key }
  }

  /// The devices a subscription's readings can be attributed to: the Account's Macs, and this
  /// iPhone for what it read itself.
  var readingDeviceNames: [String: String] {
    var names = [ThisDevice.sourceID: ThisDevice.displayName]
    for device in summary?.devices ?? [] {
      names[device.id] = device.displayName
    }
    return names
  }

  private var isPendingSession: Bool {
    sessionActivation == .pending
  }

  /// Put what the summary read answered on screen. The widget and the alerts follow the whole
  /// pass, so what is left for them is handed back rather than done here.
  private func apply(_ result: AccountRefreshResult) async -> SummaryFollowUp {
    let previousETag = summaryETag
    let previousSummary = summary
    summary = result.summary
    fetchedAt = result.fetchedAt
    fromCache = result.fromCache
    summaryETag = result.etag
    usage.accountSummaryAccepted(result.summary, etag: result.etag)
    if isPendingSession {
      await applyPending(result)
      return .none
    }
    let followUp: SummaryFollowUp
    switch result.error {
    case .none:
      banner = nil
      expiredMessage = nil
      phase = .signedIn
      followUp = .publish
    case .sessionExpired:
      applyExpired()
      followUp = .none
    case .notSignedIn:
      // Signing out, or never having signed in, is not an expiry. Saying a session expired to
      // someone who deliberately logged out invents a failure that did not happen.
      applySignedOut()
      followUp = .none
    case .relay(.unavailable), .relay(.timeout):
      phase = .signedIn
      banner = failureBanner(hasCachedSummary: result.summary != nil, offline: true)
      followUp = .afterFailure(hasTrustedSummary: result.summary != nil)
    case .some:
      phase = .signedIn
      banner = failureBanner(hasCachedSummary: result.summary != nil, offline: false)
      followUp = .afterFailure(hasTrustedSummary: result.summary != nil)
    }
    if phase == .signedIn {
      resolvePendingSubscriptionSelection()
      pruneOverviewPath()
      usage.revalidateActivityIfSummaryChanged(
        previousETag: previousETag,
        previousSummary: previousSummary,
        result: result
      )
      await accountSettings.refresh()
    }
    return followUp
  }

  private func applyPending(_ result: AccountRefreshResult) async {
    switch result.error {
    case .none:
      if let label = PlanDisplay.accountLabel(result.summary?.account.displayLabel) {
        banner = nil
        expiredMessage = nil
        phase = .confirmingAccount(label: label)
      } else {
        presentPendingRefreshFailure(message: AuthorizationError.genericConnectFailureMessage)
      }
    case .sessionExpired:
      await revokePendingSession()
      applySignedOut()
      banner = Banner(
        kind: .refreshFailed,
        text: AuthorizationError.expiredSignInMessage,
        symbolName: "exclamationmark.triangle"
      )
    case .notSignedIn:
      forgetSession()
      applySignedOut()
    case .some(let error) where isExpiredConnectError(error):
      await revokePendingSession()
      applySignedOut()
      banner = Banner(
        kind: .refreshFailed,
        text: error.userFacingMessage,
        symbolName: "exclamationmark.triangle"
      )
    case .some(let error):
      presentPendingRefreshFailure(message: error.userFacingMessage)
    }
  }

  private func isExpiredConnectError(_ error: AccountClientError) -> Bool {
    error.userFacingMessage == AuthorizationError.expiredSignInMessage
  }

  private func revokePendingSession() async {
    await account.logout()
    forgetSession()
  }

  private func presentPendingRefreshFailure(message: String) {
    banner = Banner(
      kind: .refreshFailed,
      text: message,
      symbolName: "exclamationmark.triangle"
    )
    expiredMessage = nil
    phase = .pendingRefreshFailed
  }

  private func pruneOverviewPath() {
    let keys = Set(subscriptions.map(\.key))
    overviewPath.removeAll { !keys.contains($0) }
  }

  /// A failed Relay read leaves the published snapshot alone: the reader already has last-good
  /// data, and republishing an unchanged reading only moves the widget's age. A local collection
  /// that answered in the same pass is new data, so it is published anyway. With nothing left
  /// worth drawing — no trusted summary and nothing this phone read — the widget is cleared.
  private func syncWidgetAfterFailure(hasTrustedSummary: Bool, collected: Bool) {
    if collected {
      publishWidget()
    } else if !hasTrustedSummary && subscriptions.isEmpty {
      clearWidget()
    }
  }

  private func failureBanner(hasCachedSummary: Bool, offline: Bool) -> Banner {
    if hasCachedSummary {
      return Banner(
        kind: offline ? .offlineCached : .refreshFailed,
        text: Banner.cachedText,
        symbolName: offline ? "icloud.slash" : "exclamationmark.triangle"
      )
    }
    return Banner(
      kind: .refreshFailed,
      text: Banner.failedText,
      symbolName: "exclamationmark.triangle"
    )
  }

  private func applyExpired() {
    applySignedOut()
    expiredMessage = "Session expired. Connect again."
  }

  /// Connect with GitHub with nothing said about why: no session, or one the person ended. There is
  /// no account left to read, so the standing background-refresh ask goes with it.
  private func applySignedOut() {
    summary = nil
    fetchedAt = nil
    summaryETag = nil
    fromCache = false
    banner = nil
    expiredMessage = nil
    forgetSession()
    phase = .signedOut
    identities = .idle
    linkingProvider = nil
    linkFailure = nil
    selectedTab = .quota
    pendingSubscriptionSelection = nil
    overviewPath = []
    accountSessionEpoch += 1
    stopCollectionDemand()
    usage.accountWentAway()
    quotaHistory.clear()
    // The providers this phone signed in to are not the account's, so what it collects for
    // itself survives losing the account — and so does the background window that refreshes it.
    updateBackgroundRefreshAsk()
    try? selectionSaltStore.clear()
    resetScheduler.removeAll()
    if localCollection?.snapshots.isEmpty != false {
      alertCoordinator.clearState()
    }
    publishWidget()
    evaluateAlerts()
  }

  /// Something on this phone can still be read: an account to read from Relay, or a provider
  /// session this device reads for itself. A session that has been issued but not confirmed is
  /// not one yet, so it books no window.
  private var hasSomethingToRead: Bool {
    phase == .signedIn || !providers.sessions.isEmpty
  }

  private func scheduleBackgroundRefresh() {
    guard hasSomethingToRead else { return }
    backgroundRefresh.scheduleNextRefresh()
  }

  /// Ask for the next window, or withdraw the standing ask when nothing is left to read: a phone
  /// with neither an account nor a provider session would wake only to discover that and go back
  /// to sleep.
  private func updateBackgroundRefreshAsk() {
    if hasSomethingToRead {
      backgroundRefresh.scheduleNextRefresh()
    } else {
      backgroundRefresh.cancelPendingRefresh()
    }
  }

  /// Compare the latest Account readings against the last available ones, hand events to the
  /// sink, and rebuild reset reminders. A `windowReset` whose selector and window already have
  /// a scheduled reminder is left to that reminder.
  private func evaluateAlerts() {
    let instant = now()
    let readings = subscriptions
    let catalog = AlertCoordinator.catalog(from: readings)
    if let userNotificationSink {
      userNotificationSink.catalog = catalog
      userNotificationSink.scheduledResetKeys = resetScheduler.scheduledResetKeys
      userNotificationSink.now = instant
    }
    alertCoordinator.evaluate(subscriptions: readings)
    resetScheduler.reschedule(
      rules: alertCoordinator.currentRules(),
      subscriptions: AlertCoordinator.readings(from: readings),
      catalog: catalog,
      now: instant
    )
  }

  /// Republish the widget snapshot from the merged readings. The widget does not distinguish
  /// where a reading came from, and neither does this: what it draws is what Overview shows.
  private func publishWidget() {
    let readings = subscriptions
    guard !readings.isEmpty || summary != nil else {
      clearWidget()
      return
    }
    guard let salt = try? selectionSaltStore.loadOrCreate() else { return }
    let observed = [fetchedAt, localCollection?.collectedAt].compactMap { $0 }.max()
    let snapshot = WidgetSnapshotProjection.make(
      subscriptions: readings,
      today: summary?.usage.today,
      fetchedAt: observed ?? now(),
      salt: salt
    )
    try? widgetPublisher.publish(snapshot)
  }

  private func clearWidget() {
    try? widgetPublisher.clear()
  }

  #if DEBUG
    func waitForFirstContent() async {
      if firstContentSignaled { return }
      await withCheckedContinuation { firstContentWaiter = $0 }
    }

    private func signalFirstContent() {
      firstContentSignaled = true
      let waiter = firstContentWaiter
      firstContentWaiter = nil
      waiter?.resume()
    }

    /// Test/fixture seam: set the Account session the way `restore()` would after reading Keychain.
    func poseSession(activation: AccountSessionActivation?, deviceID: String? = nil) {
      sessionActivation = activation
      sessionDeviceID = deviceID
    }

    /// One coherent Account/Overview pose. Scenarios call this instead of assigning fields.
    func pose(
      phase: Phase,
      sessionActivation: AccountSessionActivation?,
      sessionDeviceID: String?,
      summary: AccountSummary?,
      fetchedAt: Date?,
      fromCache: Bool,
      isRefreshing: Bool,
      collectionDemand: CollectionDemand? = nil,
      pendingReadings: Set<String>,
      refreshReads: Int,
      banner: Banner?,
      expiredMessage: String?,
      localCollection: LocalCollection?,
      localSamples: LocalQuotaSamples,
      selectedTab: AppTab,
      presentsSignIn: Bool,
      identities: IdentitiesPhase,
      providerStatus: [ProviderID: ProviderStatusReading],
      skipsRestore: Bool,
      isOfflineFixture: Bool,
      displayClockIsFixed: Bool
    ) {
      self.skipsRestore = skipsRestore
      self.isOfflineFixture = isOfflineFixture
      self.displayClockIsFixed = displayClockIsFixed
      self.sessionActivation = sessionActivation
      self.sessionDeviceID = sessionDeviceID
      self.phase = phase
      self.summary = summary
      self.fetchedAt = fetchedAt
      self.fromCache = fromCache
      self.isRefreshing = isRefreshing
      self.collectionDemand = collectionDemand
      self.pendingReadings = pendingReadings
      self.refreshReads = refreshReads
      self.banner = banner
      self.expiredMessage = expiredMessage
      self.localCollection = localCollection
      self.localSamples = localSamples
      self.selectedTab = selectedTab
      self.presentsSignIn = presentsSignIn
      self.identities = identities
      self.providerStatus = providerStatus
      usage.accountSummaryAccepted(summary, etag: nil)
      providers.markNeedsSignIn(localCollection?.needsSignIn ?? [])
    }

    func applyFixtureRoute(_ route: FixtureRoute) {
      switch route {
      case .usageRoot:
        selectedTab = .usage
        usagePath = []
      case .usageToday:
        selectedTab = .usage
        usagePath = []
        usage.selectUsagePeriod(.today)
      case .usageCustom:
        selectedTab = .usage
        usagePath = []
        if let range = FixtureRoute.customRange(today: displayNow) {
          usage.selectUsagePeriod(range)
        }
      case .usageBreakdown:
        selectedTab = .usage
        usagePath = [.breakdown]
      case .usagePatterns:
        selectedTab = .usage
        usagePath = [.patterns]
      case .usageDay:
        selectedTab = .usage
        usagePath = []
        if usage.activityDaySheet == nil {
          let date = usage.activityToday
          let headline =
            usage.activityChart.days?.first { $0.date == date }
            ?? UsageActivityChart.emptyDay(date: date)
          let agents: ActivityDayAgentsPhase =
            headline.totals.totalTokens > 0
            ? .loaded(VisualFixtureContent.dayAgents()) : .empty
          usage.pose(
            daySheet: ActivityDaySheetState(
              date: date,
              headline: headline,
              agents: agents
            )
          )
        }
      case .subscriptionDetail(let key):
        selectedTab = .quota
        overviewPath = [key]
      case .settingsRoot:
        selectedTab = .settings
        settingsPath = []
      case .settingsDevices:
        selectedTab = .settings
        settingsPath = [.devices]
      case .settingsNotifications:
        selectedTab = .settings
        settingsPath = [.notifications]
      case .settingsAppearance:
        selectedTab = .settings
        settingsPath = [.appearance]
      case .settingsAbout:
        selectedTab = .settings
        settingsPath = [.about]
      }
    }
  #endif
}

/// Which sides of the Overview merge answered on this phone.
struct OverviewSources: Equatable, Sendable {
  var hasLocal: Bool
  var hasAccount: Bool

  var isEmpty: Bool { !hasLocal && !hasAccount }
}

struct ProviderQuotaCardModel: Identifiable, Equatable {
  var id: ProviderID { provider }
  let provider: ProviderID
  let subscriptions: [QuotaSubscription]
}

