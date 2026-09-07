import AuthenticationServices
import Foundation
import Observation
import UIKit
import QuotaAccount
import QuotaAlerts
import QuotaPresentation
import QuotaProviderSessions
import QuotaProviderStatus
import QuotaRelay
import QuotaWidgetData
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
  private let iosAlertSink: IOSAlertSink?
  private let resetScheduler: IOSResetReminderScheduler
  private let activity: any ActivityLoading
  private let localStore: any LocalCollectionStoring
  private let sampleStore: any LocalQuotaSampleStoring
  private let localCollector: LocalCollector
  private let installation: any InstallationIdentifying
  private let providerStatusClient: any ProviderStatusServing
  private let budgetStore: UsageBudgetStore
  private let now: @Sendable () -> Date

  /// The provider sessions this phone signed in for, and the consent behind them. Settings owns
  /// the rows; the sessions themselves are the Keychain store's.
  let providers: ProvidersModel
  /// The store side of paid sync. It buys; Relay's `entitlement` is what says sync is on.
  let subscription: SubscriptionModel

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
  var banner: Banner?
  var expiredMessage: String?
  var selectedTab: AppTab = .overview
  var usagePeriod: UsagePeriodSelection = .last30Days
  /// The monthly budget this device keeps, which is a preference and never leaves it.
  var budget: UsageBudget
  /// Selection id from a subscription deep link, held until a summary can name it.
  var pendingSubscriptionSelection: String?
  /// Subscription keys on the Overview stack. A matching deep link replaces this with one key.
  var overviewPath: [String] = []
  /// Last 365 UTC days. Memory only; a failed read stays here and does not block the period list.
  var activityChart: ActivityChartPhase = .idle
  /// The selected period's hour-of-day rhythm, asked with `detail=hours`.
  var activityRhythm: ActivityRhythmPhase = .idle
  /// Presented day sheet, if any.
  var activityDaySheet: ActivityDaySheetState?
  /// The managed Account session this device holds, and how far along it is. Not private because
  /// a visual fixture states it the way it states `phase`: what Usage, Devices, and the Settings
  /// account group show turns on whether there is an account, not on which phase the app is in.
  var sessionActivation: AccountSessionActivation?
  /// The Device this phone's session speaks for, or nil when it registered none. Devices lists
  /// that row as the Account's rather than synthesizing a second one beside it.
  var sessionDeviceID: String?
  /// Whether Relay refused this phone's last upload because paid sync is off. The entitlement on
  /// the summary usually says the same thing; this is the write boundary saying it
  /// ([ADR 0033](../../../docs/decisions/0033-entitlement-is-read-from-revenuecat.md)).
  private(set) var uploadRefusedAsUnpaid = false
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
  /// Last-good official status-page readings, fetched on this device. Relay does not carry them.
  var providerStatus: [ProviderID: ProviderStatusReading] = [:]
  /// How often the foreground app polls official status pages. The helper uses the same interval.
  static let providerStatusInterval: TimeInterval = 600
  @ObservationIgnored
  private var providerStatusTimer: Timer?
  @ObservationIgnored
  private var sceneObservers: [any NSObjectProtocol] = []

  #if DEBUG
    /// When true, `QuotaApp` skips `restore()` so visual fixtures stay offline and deterministic.
    var skipsRestore = false
  #endif

  init(
    account: AccountClient,
    authenticator: any BrowserSessionAuthenticating,
    widgetPublisher: any WidgetSnapshotPublishing = NoOpWidgetSnapshotPublisher(),
    selectionSaltStore: any SelectionSaltStore = InMemorySelectionSaltStore(),
    backgroundRefresh: any BackgroundRefreshScheduling = NoOpBackgroundRefreshScheduler(),
    alertCoordinator: AlertCoordinator? = nil,
    alertRulesStore: IOSAlertRulesStore? = nil,
    alertStateStore: (any IOSAlertStateStore)? = nil,
    notificationCenter: (any NotificationCentering)? = nil,
    makeAuthorizationAttempt: @escaping @Sendable () throws -> AuthorizationAttempt = {
      try AuthorizationRequest.make()
    },
    activity: (any ActivityLoading)? = nil,
    providerSessions: any ProviderSessionStoring = KeychainProviderSessionStore(),
    localStore: any LocalCollectionStoring = MemoryLocalCollectionStore(),
    sampleStore: any LocalQuotaSampleStoring = MemoryLocalQuotaSampleStore(),
    localCollector: LocalCollector? = nil,
    purchases: any PurchasesFacade = UnconfiguredPurchases(),
    providerStatusClient: any ProviderStatusServing = IdleProviderStatusClient(),
    budgetStore: UsageBudgetStore = UsageBudgetStore(),
    installation: any InstallationIdentifying = KeychainInstallationIdentity(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.installation = installation
    self.providers = ProvidersModel(store: providerSessions)
    self.localStore = localStore
    self.sampleStore = sampleStore
    self.localCollector =
      localCollector ?? LocalCollector(sessions: providerSessions, now: now)
    self.budgetStore = budgetStore
    self.budget = budgetStore.load()
    self.account = account
    self.authenticator = authenticator
    self.widgetPublisher = widgetPublisher
    self.selectionSaltStore = selectionSaltStore
    self.backgroundRefresh = backgroundRefresh
    self.now = now
    self.makeAuthorizationAttempt = makeAuthorizationAttempt
    let center = notificationCenter ?? NoOpNotificationCenter()
    let sink = IOSAlertSink(center: center)
    self.resetScheduler = IOSResetReminderScheduler(center: center)
    if let alertCoordinator {
      self.alertCoordinator = alertCoordinator
      self.iosAlertSink = nil
    } else {
      self.iosAlertSink = sink
      self.alertCoordinator = AlertCoordinator(
        rulesStore: alertRulesStore ?? IOSAlertRulesStore(),
        stateStore: alertStateStore ?? InMemoryIOSAlertStateStore(),
        budgetStore: budgetStore,
        sink: sink,
        now: now
      )
    }
    self.activity = activity ?? AccountClientActivityLoading(client: account)
    self.providerStatusClient = providerStatusClient
    let subscription = SubscriptionModel(purchases: purchases)
    self.subscription = subscription
    subscription.onStoreChange = { [weak self] in
      await self?.refresh()
    }
  }

  convenience init(backgroundRefresh: any BackgroundRefreshScheduling) {
    self.init(
      account: AccountClient(
        sessionStore: KeychainAccountSessionStore(),
        summaryStore: (try? ProtectedFileAccountSummaryStore.applicationSupport())
          ?? MemoryAccountSummaryStore()
      ),
      authenticator: SystemBrowserAuthenticator(),
      widgetPublisher: AppGroupWidgetSnapshotPublisher.make(),
      selectionSaltStore: KeychainSelectionSaltStore(),
      backgroundRefresh: backgroundRefresh,
      alertStateStore: FileIOSAlertStateStore.applicationSupport(),
      notificationCenter: IOSNotificationCenter(),
      localStore: FileLocalCollectionStore.applicationSupport() ?? MemoryLocalCollectionStore(),
      sampleStore: FileLocalQuotaSampleStore.applicationSupport()
        ?? MemoryLocalQuotaSampleStore(),
      purchases: RevenueCatPurchases.apiKey().map { RevenueCatPurchases(apiKey: $0) }
        ?? UnconfiguredPurchases(),
      providerStatusClient: ProviderStatusClient()
    )
  }

  /// The Overview title. Without an account there is no label to print, and the app is still
  /// showing quota, so it says what it is showing.
  /// What Relay last said paid sync is worth to this Account. An Account read that has not
  /// happened yet is `none`: nothing has been bought until a summary says so.
  var entitlement: AccountEntitlement {
    summary?.entitlement ?? .unsubscribed
  }

  var isSyncOn: Bool {
    entitlement.status.allowsSync && !uploadRefusedAsUnpaid
  }

  /// What this phone presents when it signs in, so its session names a Device and what it reads
  /// can reach the Macs ([ADR 0041](../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)).
  private var deviceRegistration: IosDeviceRegistration? {
    ThisIPhone.registration(identity: installation)
  }

  /// The Overview banner a signed-in Account without paid sync gets. Its Macs keep collecting;
  /// none of what they send reaches this Account until sync is on.
  var syncBanner: String? {
    guard phase == .signedIn, summary != nil, !isSyncOn else { return nil }
    return SyncCopy.offBanner
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

  func restore() async {
    localCollection = try? localStore.load()
    localSamples = (try? sampleStore.load()) ?? LocalQuotaSamples()
    providers.markNeedsSignIn(localCollection?.needsSignIn ?? [])
    let cached = try? await account.loadCachedSummary()
    let session = try? await account.loadSession()
    sessionActivation = session?.activation
    sessionDeviceID = session?.deviceID
    summary = cached?.summary
    fetchedAt = cached?.fetchedAt
    fromCache = cached != nil
    switch session?.activation {
    case .active:
      phase = .signedIn
      // Publish what was already on disk so the widget is current before the network is.
      if cached != nil { publishWidget() }
      resolvePendingSubscriptionSelection()
      await refresh()
    case .pending:
      if let label = PlanDisplay.accountLabel(cached?.summary.account.displayLabel) {
        phase = .confirmingAccount(label: label)
      } else {
        await refresh()
        if phase == .launching {
          presentPendingRefreshFailure(
            message: AuthorizationError.genericConnectFailureMessage
          )
        }
      }
    case nil:
      // Signed out is not empty any more: the providers this phone signed in to are still
      // readable, and the last reading of them is already loaded. The refresh below publishes
      // what that comes to; the widget keeps the previous snapshot until it does.
      phase = .signedOut
      resolvePendingSubscriptionSelection()
      await refresh()
    }
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
    uploadRefusedAsUnpaid = false
  }

  private func forgetSession() {
    sessionActivation = nil
    sessionDeviceID = nil
    uploadRefusedAsUnpaid = false
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
    fromCache = false
    clearWidget()
    await connectAccount(switchingAccount: true)
  }

  /// The one refresh the pull-to-refresh gesture and a background app refresh both run: read the
  /// providers this phone signed in to and, when there is an account, the account summary — at
  /// the same time, because neither waits on the other — then merge them, republish the widget
  /// snapshot, evaluate local remaining-quota alerts, rebuild reset reminders, and ask for the
  /// next background window. Reports whether either side answered, which is the success a
  /// `BGAppRefreshTask` completes with.
  ///
  /// The next window is only worth asking for while something is left to read. A phone with
  /// neither an account nor a provider session withdraws the standing ask on its way out.
  @discardableResult
  func refresh(budget: Duration = LocalCollector.foregroundBudget) async -> Bool {
    guard !isRefreshing else { return false }
    isRefreshing = true
    defer { isRefreshing = false }
    #if DEBUG
      if !skipsRestore {
        await refreshProviderStatus()
      }
    #else
      await refreshProviderStatus()
    #endif
    let collector = localCollector
    let collects = !providers.sessions.isEmpty
    async let collected: LocalCollection? =
      collects ? await collector.collect(within: budget) : nil
    // The session is read from its store rather than from what a previous read left in memory: a
    // background refresh can run before anything has restored.
    let reads = (try? await account.hasSession()) ?? false
    let result: AccountRefreshResult? = reads ? await account.fetchTodaySummary() : nil
    let collection = await collected
    if let collection { applyLocalCollection(collection) }
    if let result {
      await apply(result, collected: collection != nil)
      await uploadLocalReadings(collection)
      scheduleBackgroundRefresh()
    } else {
      applyWithoutAccount()
    }
    // `result?.error == nil` would answer true for a refresh that never read at all, so what
    // each side actually answered is asked separately.
    return (result.map { $0.error == nil } ?? false) || collection != nil
  }

  /// A provider sign-in was kept or removed. What this phone can read changed, so the readings
  /// on screen and the standing background ask both follow it.
  func providerSessionsChanged() async {
    updateBackgroundRefreshAsk()
    await refresh()
  }

  /// Send what this phone just read to the Account, when it is a Device and sync is paid for.
  ///
  /// Only the readings go: the provider sessions behind them stay in this device's Keychain, and
  /// Usage is a Mac's, because this phone has none
  /// ([ADR 0041](../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)). A 402 is
  /// the boundary saying sync is off, and it stops this phone uploading until a summary says
  /// otherwise.
  private func uploadLocalReadings(_ collection: LocalCollection?) async {
    // Each refresh asks again: an entitlement that has just been bought is not still refused.
    uploadRefusedAsUnpaid = false
    guard let collection, !collection.snapshots.isEmpty else { return }
    guard sessionDeviceID != nil, sessionActivation == .active,
      entitlement.status.allowsSync
    else { return }
    if await account.uploadSnapshots(collection.snapshots) == .subscriptionRequired {
      uploadRefusedAsUnpaid = true
    }
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
    if isForeground {
      await startProviderStatusPolling()
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
    let readings = await providerStatusClient.refresh()
    providerStatus = Dictionary(uniqueKeysWithValues: readings.map { ($0.provider, $0) })
  }

  private func startProviderStatusPolling() async {
    #if DEBUG
      if skipsRestore { return }
    #endif
    guard providerStatusTimer == nil else { return }
    await refreshProviderStatus()
    let timer = Timer(timeInterval: Self.providerStatusInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        await self?.refreshProviderStatus()
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
    selectedTab = .overview
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

  var activityToday: String {
    UsageActivityCalendar.utcDay(from: now())
  }

  var activityDateRange: (from: String, to: String) {
    UsageActivityCalendar.range(endingOn: activityToday)
  }

  /// The dates the selected period covers, or nil for `all`, which names no first day.
  var usagePeriodRange: (from: String, to: String)? {
    usagePeriod.range(today: now())
  }

  /// The title above the totals: the range the selected period covers.
  var usagePeriodTitle: String {
    UsagePeriodTitle.text(for: usagePeriod, today: now())
  }

  /// The days a folded period may reach back over, which is what the activity read answered.
  var usageEarliestDay: String {
    activityDateRange.from
  }

  /// The activity days this device has, which is what a folded period is added up from.
  var activityDays: [UsageActivityDay] {
    if case .loaded(let days) = activityChart { return days }
    return []
  }

  /// The selected period, read from the summary when it folds it and added up here when not.
  ///
  /// The summary answers four periods exactly, in the caller's own calendar. Anything else is
  /// the activity days the page already holds, which are UTC days: a range is chosen in this
  /// device's calendar and folded from the UTC days carrying those dates.
  var usagePeriodValue: UsagePeriod? {
    if let key = usagePeriod.summaryKey, let usage = summary?.usage {
      return period(usage, key)
    }
    guard let range = usagePeriodRange, case .loaded(let days) = activityChart else { return nil }
    return UsageDayFold.period(days, from: range.from, to: range.to)
  }

  /// Whether the shown period was added up here, which is why it has no model breakdown.
  var usagePeriodIsFolded: Bool {
    usagePeriod.summaryKey == nil
  }

  /// How far into this month's budget its spend has gone, or nil when there is no budget yet.
  var budgetProgress: UsageBudgetProgress? {
    guard let amount = budget.amountUSD,
      let range = UsagePeriodSelection.thisMonth.range(today: now()),
      case .loaded(let days) = activityChart
    else { return nil }
    let month = UsageDayFold.period(days, from: range.from, to: range.to)
    let spent = UsageBudgetProgress.dollars(microusd: month.cost.amountMicrousd) ?? 0
    return UsageBudgetProgress(
      spentUSD: spent,
      budgetUSD: amount,
      partial: month.cost.status != .complete
    )
  }

  func selectUsagePeriod(_ selection: UsagePeriodSelection) {
    usagePeriod = selection
    activityRhythm = .idle
  }

  func setBudget(_ next: UsageBudget) {
    budget = budgetStore.save(next)
    evaluateBudgetAlerts()
  }

  /// Says once per month that 80% and then 100% of the budget has been spent.
  func evaluateBudgetAlerts() {
    alertCoordinator.evaluateBudget(budget: budget, progress: budgetProgress)
  }

  private func period(_ usage: AccountUsage, _ key: UsageSummaryPeriodKey) -> UsagePeriod {
    switch key {
    case .today: usage.today
    case .last7Days: usage.last7Days
    case .last30Days: usage.last30Days
    case .all: usage.all
    }
  }

  /// First visit to Usage asks once. Retry is explicit. The answer stays in memory.
  func loadActivity(force: Bool = false) async {
    guard phase == .signedIn else { return }
    if !force {
      switch activityChart {
      case .idle: break
      case .loading, .loaded, .failed: return
      }
    } else if case .loading = activityChart {
      return
    }
    activityChart = .loading
    let range = activityDateRange
    let result = await activity.fetchUsageActivity(
      from: range.from,
      to: range.to,
      detail: nil,
      timeZone: nil
    )
    guard phase == .signedIn else { return }
    applyActivity(result)
  }

  /// The selected period's rhythm, omitted for All, which has no first day.
  func loadRhythm(force: Bool = false) async {
    guard phase == .signedIn, let range = usagePeriodRange else {
      activityRhythm = .idle
      return
    }
    if !force {
      switch activityRhythm {
      case .idle: break
      case .loading, .loaded, .failed: return
      }
    } else if case .loading = activityRhythm {
      return
    }
    activityRhythm = .loading
    let result = await activity.fetchUsageActivity(
      from: range.from,
      to: range.to,
      detail: .hours,
      timeZone: TimeZone.current.identifier
    )
    guard phase == .signedIn, usagePeriodRange?.from == range.from,
      usagePeriodRange?.to == range.to
    else { return }
    applyRhythm(result)
  }

  func retryActivity() async {
    await loadActivity(force: true)
  }

  func openActivityDay(date: String) async {
    guard phase == .signedIn else { return }
    presentActivityDay(date: date)
    await loadActivityDayAgents()
  }

  func presentActivityDay(date: String) {
    activityDaySheet = ActivityDaySheetState(
      date: date,
      headline: reportedDay(on: date),
      agents: .loading
    )
  }

  func retryActivityDay() async {
    guard activityDaySheet != nil else { return }
    updateDaySheet { $0.agents = .loading }
    await loadActivityDayAgents()
  }

  private func loadActivityDayAgents() async {
    guard let current = activityDaySheet else { return }
    let result = await activity.fetchUsageActivity(
      from: current.date,
      to: current.date,
      detail: .agents,
      timeZone: nil
    )
    guard phase == .signedIn, activityDaySheet?.date == current.date else { return }
    switch result {
    case .activity(let response):
      applyDayDetail(response, onto: current.date)
    case .failure(.sessionExpired):
      applyExpired()
    case .failure(.notSignedIn):
      applySignedOut()
    case .failure:
      updateDaySheet { $0.agents = .failed }
    }
  }

  private func applyActivity(_ result: AccountActivityResult) {
    switch result {
    case .activity(let response):
      activityChart = .loaded(response.days)
      evaluateBudgetAlerts()
    case .failure(.sessionExpired):
      applyExpired()
    case .failure(.notSignedIn):
      applySignedOut()
    case .failure:
      activityChart = .failed
    }
  }

  private func applyRhythm(_ result: AccountActivityResult) {
    switch result {
    case .activity(let response):
      if let hours = response.hoursOfDay, let weekdays = response.weekdayHours,
        hours.contains(where: { $0.totalTokens > 0 })
      {
        activityRhythm = .loaded(hoursOfDay: hours, weekdayHours: weekdays)
      } else {
        activityRhythm = .idle
      }
    case .failure(.sessionExpired):
      applyExpired()
    case .failure(.notSignedIn):
      applySignedOut()
    case .failure:
      activityRhythm = .failed
    }
  }

  private func applyDayDetail(_ response: AccountUsageActivityResponse, onto date: String) {
    updateDaySheet { sheet in
      if let day = response.days.first(where: { $0.date == date }) ?? response.days.first {
        sheet.headline = day
        let agents = day.agents ?? []
        sheet.agents = agents.isEmpty ? .empty : .loaded(agents)
      } else {
        sheet.agents = .empty
      }
    }
  }

  private func reportedDay(on date: String) -> UsageActivityDay {
    if case .loaded(let days) = activityChart, let day = days.first(where: { $0.date == date }) {
      return day
    }
    return UsageActivityChart.emptyDay(date: date)
  }

  private func updateDaySheet(_ mutate: (inout ActivityDaySheetState) -> Void) {
    guard var sheet = activityDaySheet else { return }
    mutate(&sheet)
    activityDaySheet = sheet
  }

  private var isPendingSession: Bool {
    sessionActivation == .pending
  }

  private func apply(_ result: AccountRefreshResult, collected: Bool) async {
    summary = result.summary
    fetchedAt = result.fetchedAt
    fromCache = result.fromCache
    if isPendingSession {
      await applyPending(result)
      return
    }
    switch result.error {
    case .none:
      banner = nil
      expiredMessage = nil
      phase = .signedIn
      publishWidget()
      evaluateAlerts()
      await identifySubscriber()
    case .sessionExpired:
      applyExpired()
    case .notSignedIn:
      // Signing out, or never having signed in, is not an expiry. Saying a session expired to
      // someone who deliberately logged out invents a failure that did not happen.
      applySignedOut()
    case .relay(.unavailable), .relay(.timeout):
      phase = .signedIn
      banner = failureBanner(hasCachedSummary: result.summary != nil, offline: true)
      syncWidgetAfterFailure(hasTrustedSummary: result.summary != nil, collected: collected)
    case .some:
      phase = .signedIn
      banner = failureBanner(hasCachedSummary: result.summary != nil, offline: false)
      syncWidgetAfterFailure(hasTrustedSummary: result.summary != nil, collected: collected)
    }
    if phase == .signedIn {
      resolvePendingSubscriptionSelection()
      pruneOverviewPath()
    }
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
    fromCache = false
    banner = nil
    expiredMessage = nil
    forgetSession()
    phase = .signedOut
    identities = .idle
    linkingProvider = nil
    linkFailure = nil
    selectedTab = .overview
    usagePeriod = .last30Days
    pendingSubscriptionSelection = nil
    overviewPath = []
    activityChart = .idle
    activityRhythm = .idle
    activityDaySheet = nil
    // The providers this phone signed in to are not the account's, so what it collects for
    // itself survives losing the account — and so does the background window that refreshes it.
    updateBackgroundRefreshAsk()
    Task { await subscription.signOut() }
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
    if let iosAlertSink {
      iosAlertSink.catalog = catalog
      iosAlertSink.scheduledResetKeys = resetScheduler.scheduledResetKeys
      iosAlertSink.now = instant
    }
    alertCoordinator.evaluate(subscriptions: readings)
    resetScheduler.reschedule(
      rules: alertCoordinator.currentRules(),
      subscriptions: AlertCoordinator.readings(from: readings),
      catalog: catalog,
      now: instant
    )
  }

  /// Bind store purchases to this Account, and let the paywall know Relay has caught up.
  private func identifySubscriber() async {
    guard let accountID = summary?.account.accountID else { return }
    if isSyncOn {
      subscription.entitlementConfirmed()
    }
    await subscription.identify(accountID: accountID)
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

enum ActivityChartPhase: Equatable, Sendable {
  case idle
  case loading
  case loaded([UsageActivityDay])
  case failed
}

enum ActivityRhythmPhase: Equatable, Sendable {
  case idle
  case loading
  case loaded(hoursOfDay: [QuotaWire.UsageHourOfDay], weekdayHours: [[Int]])
  case failed
}

enum ActivityDayAgentsPhase: Equatable, Sendable {
  case loading
  case loaded([UsageAgentUsage])
  case empty
  case failed
}

struct ActivityDaySheetState: Identifiable, Equatable, Sendable {
  var id: String { date }
  var date: String
  var headline: UsageActivityDay
  var agents: ActivityDayAgentsPhase
}
