import Foundation
import Observation
import QuotaWire
import SweetCookieKit

/// The IPC calls browser-session acquisition makes. The rest of the local service stays on
/// the app coordinator.
protocol BrowserConnectionTransport: Sendable {
  func setProviderBrowserScan(_ provider: ProviderID, enabled: Bool) async throws
    -> LocalServiceProviderBrowserScanSetting
  func replaceProviderBrowserSessions(
    _ provider: ProviderID,
    cookieHeaders: [String],
    accessDenials: [BrowserAccessDenial]
  ) async throws
}

/// Which browsers one scan opened and which it left shut, by display name.
struct BrowserScanCoverage: Equatable, Sendable {
  var read: [String] = []
  var skipped: [String] = []
  /// Sign-ins the scan found and sent to the service, whether or not it accepted them.
  var candidates = 0
}

enum ProviderBrowserSessionPopup: Equatable, Sendable, Identifiable {
  /// Asked before the first cookie is read after Scan browsers is turned on.
  case consent(provider: ProviderID)

  var id: String {
    switch self {
    case .consent(let provider): "consent:\(provider.rawValue)"
    }
  }
}

private struct QuotaCollectionScanKey: Equatable {
  var updatedAt: Date?
}

/// Consent, cookie-store reads, reconnect, and the Browser Access grant window. Quota
/// projection and account login stay on ``MenuBarViewModel``, which hands each accepted
/// service state through ``acceptState``.
@Observable
@MainActor
final class BrowserConnectionModel: BrowserAccessGrantHandling {
  private(set) var providerBrowserSessions: [ProviderID: [LocalServiceProviderBrowserSession]] = [:]
  private(set) var browserScanEnabled: Set<ProviderID> = []
  private(set) var browserSessionPopup: ProviderBrowserSessionPopup?
  private(set) var browserSessionErrorMessages: [ProviderID: String] = [:]
  /// A read macOS refused, which is a different state from finding no session: it stands until
  /// the reader changes a permission, and the Diagnostics page carries it too.
  private(set) var browserSessionAccessDenials: [ProviderID: BrowserAccessDenial] = [:]
  private(set) var browserSessionWaitingProvider: ProviderID?
  private(set) var browserSessionActivityText: String?
  /// Every installed browser and the macOS grant it still needs, probed after Scan browsers is
  /// turned on. The Agent page summarises it in one row; the Browser Access window lists it.
  private(set) var browserAccessSnapshot = BrowserAccessSnapshot(
    statuses: [], awaitingRelaunch: false)
  /// The Chrome-family browser whose Keychain prompt is on screen right now.
  private(set) var keychainPromptBrowser: Browser?
  var browserAccessNeeds: [BrowserAccessNeed] { browserAccessSnapshot.needs }
  var browserAccessAwaitingRelaunch: Bool { browserAccessSnapshot.awaitingRelaunch }
  /// One line for the Agent page row, or nil when every installed browser is readable.
  var browserAccessSummary: String? {
    BrowserSessionCopy.accessSummary(
      needs: browserAccessNeeds, awaitingRelaunch: browserAccessAwaitingRelaunch)
  }
  /// Bumps after a browser-session replace finishes, so tests can wait on MainActor state.
  private(set) var browserSessionScanGeneration = 0
  /// What the last scan for each provider opened and skipped, so the Agent page can say
  /// where it looked.
  private(set) var browserScanCoverage: [ProviderID: BrowserScanCoverage] = [:]

  @ObservationIgnored
  private var lastBrowserScanKey: [ProviderID: QuotaCollectionScanKey] = [:]
  @ObservationIgnored
  private var lastBrowserScanFinishedAt: [ProviderID: Date] = [:]
  @ObservationIgnored
  private var lastBrowserScanEnabled: Set<ProviderID> = []
  private var scanningProviders: Set<ProviderID> = []
  /// Set when this session sent the person to the Full Disk Access pane. The grant lands on
  /// the next launch, so from then on the window offers a relaunch.
  private var fullDiskAccessSettingsOpened = false
  /// Invalidates an in-flight scan so its replace does not land after a newer request.
  @ObservationIgnored
  private var scanRequestGeneration: [ProviderID: UInt64] = [:]
  @ObservationIgnored
  private var quotaResults: [QuotaCollectionResult] = []
  @ObservationIgnored
  private var quotaRefreshIntervalSeconds = 300

  @ObservationIgnored
  private let transport: (any BrowserConnectionTransport)?

  @ObservationIgnored
  private let browserSessionImporter: any BrowserSessionImporting

  @ObservationIgnored
  private let accessProbe: any BrowserAccessProbing

  @ObservationIgnored
  private var grantPresenter: (any BrowserAccessGrantPresenting)?

  @ObservationIgnored
  private let relauncher: any QuotaBarRelaunching

  @ObservationIgnored
  private var fullDiskAccessPollTask: Task<Void, Never>?

  @ObservationIgnored
  var onNeedsReload: (@MainActor () async -> Void)?

  init(
    transport: (any BrowserConnectionTransport)?,
    importer: any BrowserSessionImporting = BrowserSessionImporter(),
    accessProbe: any BrowserAccessProbing,
    grantPresenter: (any BrowserAccessGrantPresenting)? = nil,
    relauncher: any QuotaBarRelaunching
  ) {
    self.transport = transport
    browserSessionImporter = importer
    self.accessProbe = accessProbe
    self.grantPresenter = grantPresenter
    self.relauncher = relauncher
    self.grantPresenter?.handler = self
  }

  deinit {
    fullDiskAccessPollTask?.cancel()
  }

  func start() {
    grantPresenter?.handler = self
  }

  func shutdown() {
    fullDiskAccessPollTask?.cancel()
    fullDiskAccessPollTask = nil
    grantPresenter?.dismiss()
  }

  /// Takes the browser-session slice of an accepted `get_state`. Scheduled scans key on
  /// quota `updatedAt`, not revision, matching today's `apply`.
  func acceptState(_ state: LocalServiceState) {
    providerBrowserSessions = Dictionary(grouping: state.providerBrowserSessions, by: \.provider)
    browserScanEnabled = Set(state.browserScanEnabled)
    quotaResults = state.quota.value?.results ?? []
    quotaRefreshIntervalSeconds = state.quotaRefreshIntervalSeconds
    scheduleBrowserScans(
      quotaUpdatedAt: state.quota.updatedAt, quotaRefreshing: state.quota.refreshing)
  }

  func signInBrowserState(for provider: ProviderID) -> SignInRungPresentation.BrowserState? {
    guard provider.browserSession != nil else { return nil }
    return SignInRungPresentation.BrowserState(
      isEnabled: browserScanEnabled.contains(provider),
      isScanning: scanningProviders.contains(provider),
      accountLabels: (providerBrowserSessions[provider] ?? []).compactMap(\.accountLabel),
      readBrowsers: browserScanCoverage[provider]?.read ?? [],
      skippedBrowsers: browserScanCoverage[provider]?.skipped ?? [],
      candidatesFound: browserScanCoverage[provider]?.candidates ?? 0
    )
  }

  /// Turning Scan browsers on is the consent gate. Declining leaves every cookie store shut.
  func requestEnableBrowserScan(_ provider: ProviderID) {
    guard provider.browserSession != nil else { return }
    browserSessionErrorMessages[provider] = nil
    browserSessionAccessDenials[provider] = nil
    browserSessionPopup = .consent(provider: provider)
  }

  func confirmProviderBrowserSessionConsent() {
    guard case .consent(let provider) = browserSessionPopup else { return }
    browserSessionPopup = nil
    Task { await setBrowserScan(provider, enabled: true, scanImmediately: true) }
  }

  func setBrowserScanEnabled(_ provider: ProviderID, enabled: Bool) {
    if enabled {
      requestEnableBrowserScan(provider)
      return
    }
    bumpScanGeneration(provider)
    Task { await setBrowserScan(provider, enabled: false, scanImmediately: false) }
  }

  func cancelProviderBrowserSessionFlow() {
    browserSessionPopup = nil
  }

  /// The Agent page row: re-probe, then bring the Browser Access window forward.
  func showBrowserAccessGrants() {
    refreshAccessSnapshot()
    presentBrowserAccessGrants()
  }

  func browserAccessGrantDidRequestFullDiskAccess() {
    fullDiskAccessSettingsOpened = true
    grantPresenter?.openFullDiskAccessSettings()
    refreshAccessSnapshot()
    startFullDiskAccessPolling()
  }

  func browserAccessGrantDidRequestKeychain(_ browser: Browser) {
    Task { await allowKeychain(browser) }
  }

  func browserAccessGrantDidRequestRelaunch() {
    relauncher.relaunch()
  }

  /// The icon landed in the Full Disk Access list. macOS applies that grant on the next
  /// launch, so this is the same place as having opened the pane: offer the relaunch and keep
  /// probing in case it lands sooner.
  func browserAccessGrantDidDropIntoFullDiskAccess() {
    fullDiskAccessSettingsOpened = true
    refreshAccessSnapshot()
    startFullDiskAccessPolling()
  }

  /// Closing the window changes nothing: Scan browsers stays on and the Agent page keeps the
  /// row until the grants arrive.
  func browserAccessGrantDidDismiss() {}

  func coversAccessDenial(_ denial: BrowserAccessDenial) -> Bool {
    switch denial.reason {
    case .fullDiskAccess:
      browserAccessNeeds.contains { $0.kind == .fullDiskAccess }
    case .keychainRefused:
      browserAccessNeeds.contains {
        $0.kind == .keychain && $0.browser.displayName == denial.browserName
      }
    case .storeUnreadable:
      false
    }
  }

  private func setBrowserScan(
    _ provider: ProviderID,
    enabled: Bool,
    scanImmediately: Bool
  ) async {
    guard let transport else { return }
    browserSessionWaitingProvider = provider
    browserSessionActivityText = enabled ? "Checking access…" : "Turning off…"
    defer {
      if browserSessionWaitingProvider == provider {
        browserSessionWaitingProvider = nil
        browserSessionActivityText = nil
      }
    }
    do {
      _ = try await transport.setProviderBrowserScan(provider, enabled: enabled)
      if enabled {
        browserScanEnabled.insert(provider)
        refreshAccessSnapshot()
        presentBrowserAccessGrants()
        if scanImmediately, !officialCredentialUsable(for: provider) {
          browserSessionActivityText = "Scanning browsers…"
          await scanAndReplaceBrowserSessions(provider)
        }
      } else {
        browserScanEnabled.remove(provider)
        providerBrowserSessions[provider] = []
        browserSessionAccessDenials[provider] = nil
        browserSessionErrorMessages[provider] = nil
        if browserScanEnabled.isEmpty {
          fullDiskAccessSettingsOpened = false
          fullDiskAccessPollTask?.cancel()
          fullDiskAccessPollTask = nil
          browserAccessSnapshot = BrowserAccessSnapshot(statuses: [], awaitingRelaunch: false)
          grantPresenter?.dismiss()
        } else {
          refreshAccessSnapshot()
        }
      }
      await onNeedsReload?()
    } catch is CancellationError {
      return
    } catch {
      browserSessionErrorMessages[provider] = Self.message(for: error)
    }
  }

  /// Reads every installed browser the current access snapshot allows and hands the service
  /// the whole result. A browser the snapshot says is closed is recorded as a refusal, not
  /// opened: a scheduled scan must never be the thing that shows a permission prompt.
  private func scanAndReplaceBrowserSessions(_ provider: ProviderID) async {
    guard let transport, let spec = provider.browserSession else { return }
    guard scanningProviders.insert(provider).inserted else { return }
    let generation = bumpScanGeneration(provider)
    defer {
      scanningProviders.remove(provider)
      lastBrowserScanFinishedAt[provider] = Date()
    }
    browserSessionWaitingProvider = provider
    browserSessionActivityText = "Scanning browsers…"
    defer {
      if browserSessionWaitingProvider == provider {
        browserSessionWaitingProvider = nil
        browserSessionActivityText = nil
      }
    }
    let access = browserAccessSnapshot
    var headers: [String] = []
    var seen = Set<String>()
    var denials: [BrowserAccessDenial] = []
    var coverage = BrowserScanCoverage()
    let deadline = Date().addingTimeInterval(30)
    for browser in BrowserSessionImporter.orderedBrowsers(for: spec) {
      guard !Task.isCancelled, Date() < deadline else { break }
      guard scanRequestGeneration[provider] == generation else { break }
      guard let status = access.status(for: browser) else { continue }
      switch status.state {
      case .readable:
        break
      case .needsFullDiskAccess, .needsKeychain:
        let denial = BrowserAccessDenial(
          browserName: browser.displayName,
          reason: status.state == .needsFullDiskAccess ? .fullDiskAccess : .keychainRefused
        )
        if !denials.contains(where: { $0.browserName == denial.browserName }) {
          denials.append(denial)
          browserSessionAccessDenials[provider] = denial
        }
        coverage.skipped.append(browser.displayName)
        continue
      case .unavailable:
        continue
      }
      let outcome = await browserSessionImporter.read(
        spec: spec, browser: browser, now: Date(), deadline: deadline)
      switch outcome {
      case .found(let candidates):
        coverage.read.append(browser.displayName)
        for candidate in candidates where seen.insert(candidate.headerFingerprint).inserted {
          headers.append(candidate.cookieHeader)
        }
      case .accessDenied(let denial):
        coverage.skipped.append(browser.displayName)
        if !denials.contains(where: { $0.browserName == denial.browserName }) {
          denials.append(denial)
        }
        browserSessionAccessDenials[provider] = denial
      case .noSession:
        coverage.read.append(browser.displayName)
      }
    }
    guard scanRequestGeneration[provider] == generation else { return }
    coverage.candidates = headers.count
    browserScanCoverage[provider] = coverage
    do {
      try await transport.replaceProviderBrowserSessions(
        provider, cookieHeaders: headers, accessDenials: denials)
      guard scanRequestGeneration[provider] == generation else { return }
      browserSessionScanGeneration += 1
      if denials.isEmpty {
        browserSessionAccessDenials[provider] = nil
        browserSessionErrorMessages[provider] = nil
      } else if let denial = denials.first, !coversAccessDenial(denial) {
        browserSessionErrorMessages[provider] = denial.message
      } else {
        browserSessionErrorMessages[provider] = nil
      }
    } catch is CancellationError {
      return
    } catch {
      guard scanRequestGeneration[provider] == generation else { return }
      browserSessionErrorMessages[provider] = Self.message(for: error)
    }
  }

  @discardableResult
  private func bumpScanGeneration(_ provider: ProviderID) -> UInt64 {
    let next = (scanRequestGeneration[provider] ?? 0) + 1
    scanRequestGeneration[provider] = next
    return next
  }

  private func officialCredentialUsable(for provider: ProviderID) -> Bool {
    guard let result = result(for: provider) else { return false }
    return result.sources.contains { source in
      source.outcome == .success && !Self.isBrowserSessionSource(source.sourceID)
    }
  }

  private static func isBrowserSessionSource(_ sourceID: String) -> Bool {
    SignInRungCatalog.isBrowserSource(sourceID)
  }

  /// A successful collection never re-reads a jar; auth-required is the only failure that does.
  private func shouldAutomaticallyScanBrowsers(for provider: ProviderID) -> Bool {
    let sessions = providerBrowserSessions[provider] ?? []
    guard let result = result(for: provider) else { return sessions.isEmpty }
    if result.outcome == .success { return false }
    return result.outcome == .authRequired
      || result.sources.contains { $0.category == .authRequired }
  }

  private func scheduleBrowserScans(quotaUpdatedAt: Date?, quotaRefreshing: Bool) {
    let enabledChanged = lastBrowserScanEnabled != browserScanEnabled
    lastBrowserScanEnabled = browserScanEnabled

    var providersToScan: [ProviderID] = []
    if !quotaRefreshing {
      let interval = TimeInterval(max(60, quotaRefreshIntervalSeconds))
      let now = Date()
      for provider in browserScanEnabled {
        guard shouldAutomaticallyScanBrowsers(for: provider) else { continue }
        if lastBrowserScanKey[provider] == QuotaCollectionScanKey(updatedAt: quotaUpdatedAt) {
          continue
        }
        if let finished = lastBrowserScanFinishedAt[provider],
          now.timeIntervalSince(finished) < interval
        {
          continue
        }
        providersToScan.append(provider)
      }
    }

    if (enabledChanged && !browserScanEnabled.isEmpty) || !providersToScan.isEmpty {
      refreshAccessSnapshot()
    }

    for provider in providersToScan {
      lastBrowserScanKey[provider] = QuotaCollectionScanKey(updatedAt: quotaUpdatedAt)
      Task { await scanAndReplaceBrowserSessions(provider) }
    }
  }

  private var grantSnapshot: BrowserAccessGrantSnapshot {
    BrowserAccessGrantSnapshot(
      statuses: browserAccessSnapshot.statuses,
      awaitingRelaunch: browserAccessSnapshot.awaitingRelaunch,
      keychainPromptBrowser: keychainPromptBrowser
    )
  }

  /// Probes every installed browser once and redraws the window if it is open. Closing it is
  /// the window's own decision, made when nothing is outstanding any more.
  private func refreshAccessSnapshot() {
    browserAccessSnapshot = accessProbe.snapshot(
      browsers: Browser.defaultImportOrder,
      fullDiskAccessSettingsOpened: fullDiskAccessSettingsOpened
    )
    grantPresenter?.update(grantSnapshot)
  }

  private func presentBrowserAccessGrants() {
    guard browserAccessSnapshot.hasOutstandingGrants else { return }
    grantPresenter?.present(grantSnapshot)
  }

  /// The one read that may show the Keychain prompt, because the person pressed Allow.
  private func allowKeychain(_ browser: Browser) async {
    guard keychainPromptBrowser == nil else { return }
    keychainPromptBrowser = browser
    grantPresenter?.update(grantSnapshot)
    let access = await accessProbe.requestKeychainAccess(for: browser)
    keychainPromptBrowser = nil
    refreshAccessSnapshot()
    if access == .allowed {
      await scanEnabledProvidersMissingOfficialCredentials()
    }
  }

  private func scanEnabledProvidersMissingOfficialCredentials() async {
    for provider in browserScanEnabled where !officialCredentialUsable(for: provider) {
      await scanAndReplaceBrowserSessions(provider)
    }
  }

  /// Full Disk Access usually lands on the next launch, but a cheap directory listing is worth
  /// asking for a few minutes in case it lands sooner; nothing here shows UI.
  private func startFullDiskAccessPolling() {
    fullDiskAccessPollTask?.cancel()
    fullDiskAccessPollTask = Task { @MainActor [weak self] in
      for _ in 0..<150 {
        try? await Task.sleep(for: .seconds(2))
        guard let self, !Task.isCancelled else { return }
        if self.accessProbe.hasFullDiskAccess() {
          self.fullDiskAccessSettingsOpened = false
          self.refreshAccessSnapshot()
          await self.scanEnabledProvidersMissingOfficialCredentials()
          return
        }
      }
    }
  }

  private func result(for provider: ProviderID) -> QuotaCollectionResult? {
    quotaResults.first { $0.provider == provider }
  }

  private static func message(for error: Error) -> String {
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription
    {
      return description
    }
    return "QuotaBar's local service could not complete the request."
  }
}
