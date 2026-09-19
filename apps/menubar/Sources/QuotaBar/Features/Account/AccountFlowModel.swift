import AppKit
import Foundation
import Observation
import QuotaPresentation
import QuotaWire

/// The IPC calls the Quota account flow makes. The rest of the local service stays on
/// the app coordinator.
protocol AccountFlowTransport: Sendable {
  func login() async throws -> LocalServiceLoginResult
  func cancelLogin() async throws
  func logout() async throws -> LocalServiceLogoutResult
}

enum AccountViewState: Equatable {
  case notChecked
  case signedOut
  case logoutPending
  case signedIn
}

enum AccountDisconnectReason: Equatable {
  case deviceDeleted
  case sessionEnded
}

protocol LoginURLOpening: Sendable {
  func open(_ url: URL) -> Bool
}

struct WorkspaceLoginURLOpener: LoginURLOpening {
  func open(_ url: URL) -> Bool {
    NSWorkspace.shared.open(url)
  }
}

/// Sign-in phases, pending confirmation, session identity/epoch, and sign-out. Quota
/// projection stays on ``MenuBarViewModel``, which hands each accepted service state
/// through ``acceptState``. Usage and browser-connection work carry this epoch; they
/// do not hold a second session.
@Observable
@MainActor
final class AccountFlowModel {
  private(set) var accountSummary: AccountSummary?
  /// The name the sign-in gave, held until an account read carries one of its own.
  private(set) var signInDisplayLabel: String?
  private(set) var accountErrorMessage: String?
  private(set) var accountActionErrorMessage: String?
  private(set) var isLoggingIn = false
  private(set) var isLoggingOut = false
  private(set) var accountRefreshing = false
  private(set) var accountDisconnectReason: AccountDisconnectReason?
  /// This Mac's Device id while signed in, used to mark the Devices table row.
  private(set) var accountDeviceID: String?
  /// The Account id the session speaks for. One session per client (ADR 0027).
  private(set) var accountID: String?
  /// Device generation this session opened at. Not a second session copy.
  private(set) var deviceGeneration: Int?
  private(set) var loginAuthorizeURL: URL?
  /// Incremented when the account goes away so in-flight Usage and browser work drop.
  private(set) var sessionEpoch = 0

  var canCopyLoginLink: Bool { loginAuthorizeURL != nil }

  /// True while a session is here (signed in or logout pending). `logging_in` is not a session.
  var hasAccountSession: Bool { sessionPresent }

  var accountState: AccountViewState {
    switch authStatus {
    case .signedIn: .signedIn
    case .logoutPending: .logoutPending
    case .loggingIn, .signedOut: .signedOut
    case nil: .notChecked
    }
  }

  /// What to call the account.
  ///
  /// The account read is the fuller answer, but it is not the first one: signing in already said
  /// what the account is called, so the name stands from that moment rather than from whenever
  /// the first read finishes.
  var accountDisplayLabel: String {
    PlanDisplay.accountLabel(accountSummary?.account.displayLabel)
      ?? PlanDisplay.accountLabel(signInDisplayLabel)
      ?? "Quota account"
  }

  /// Why Sync Usage cannot be turned on, or nil when it can.
  var syncUsageDisabledReason: String? {
    accountState == .signedIn ? nil : "Sign in to your Quota account"
  }

  var accountDeviceSummary: String {
    guard let devices = accountSummary?.devices else {
      return accountState == .signedIn ? "Unavailable" : "Sign in"
    }
    let instant = now()
    let active = devices.filter { $0.activity(now: instant).status == .active }.count
    return active == devices.count ? "\(devices.count)" : "\(active)/\(devices.count) active"
  }

  /// How often a sign-in in progress asks the service for its state, until the flow is over.
  nonisolated static let loginPollInterval: Duration = .seconds(2)
  /// A sign-in that has been in progress this long is no longer being followed by the poll.
  nonisolated static let loginPollLimit: Duration = .seconds(900)

  private var authStatus: LocalServiceAuthStatus?
  private var browserOpenFailed = false
  /// True while this owner currently has a session (signed in or logout pending).
  private var sessionPresent = false

  @ObservationIgnored
  private var loginTask: Task<Void, Never>?

  /// Follows a sign-in in progress by asking for state, until the service says the flow is over.
  @ObservationIgnored
  private var loginPollTask: Task<Void, Never>?

  @ObservationIgnored
  private var cancelLoginTask: Task<Void, Never>?

  /// Invalidates an in-flight sign-in so its result does not land after cancel.
  @ObservationIgnored
  private var loginGeneration: UInt64 = 0

  @ObservationIgnored
  private let transport: (any AccountFlowTransport)?

  @ObservationIgnored
  private let loginURLOpener: any LoginURLOpening

  @ObservationIgnored
  private let now: @MainActor () -> Date

  @ObservationIgnored
  private let unavailableMessage: String?

  private let loginPollInterval: Duration

  @ObservationIgnored
  var onNeedsReload: (@MainActor () async -> Void)?

  /// The coordinator and other owners: an Account session is now present.
  @ObservationIgnored
  var onAccountArrived: (@MainActor (Int) -> Void)?

  /// The coordinator and other owners: the Account session went away. `sessionEpoch` has
  /// already advanced.
  @ObservationIgnored
  var onAccountWentAway: (@MainActor (Int) -> Void)?

  init(
    transport: (any AccountFlowTransport)?,
    loginURLOpener: any LoginURLOpening = WorkspaceLoginURLOpener(),
    now: @escaping @MainActor () -> Date = { Date() },
    unavailableMessage: String? = nil,
    loginPollInterval: Duration = AccountFlowModel.loginPollInterval
  ) {
    self.transport = transport
    self.loginURLOpener = loginURLOpener
    self.now = now
    self.unavailableMessage = unavailableMessage
    self.loginPollInterval = loginPollInterval
  }

  deinit {
    loginTask?.cancel()
    loginPollTask?.cancel()
    cancelLoginTask?.cancel()
  }

  func shutdown() {
    loginTask?.cancel()
    loginTask = nil
    loginPollTask?.cancel()
    loginPollTask = nil
    cancelLoginTask?.cancel()
    cancelLoginTask = nil
  }

  /// Takes the account slice of an accepted `get_state`. Sign-in polling keys on
  /// `logging_in`, matching today's `apply`.
  func acceptState(_ state: LocalServiceState) {
    accountSummary = state.account.value?.accountSummary
    signInDisplayLabel = state.account.value?.displayLabel
    accountDeviceID = state.account.value?.deviceID
    accountID = state.account.value?.accountID
    deviceGeneration = state.account.value?.deviceGeneration
    let incomingAuth =
      state.account.value?.authStatus
      ?? (state.account.status == .signedOut ? .signedOut : nil)
    if incomingAuth == .signedIn {
      if !browserOpenFailed {
        accountActionErrorMessage = nil
      }
      loginAuthorizeURL = nil
      browserOpenFailed = false
    } else if incomingAuth == .loggingIn, authStatus != .loggingIn, !browserOpenFailed {
      accountActionErrorMessage = nil
    } else if incomingAuth != .loggingIn, authStatus == .loggingIn {
      loginAuthorizeURL = nil
      browserOpenFailed = false
    }
    authStatus = incomingAuth
    if authStatus != .loggingIn {
      loginPollTask?.cancel()
      loginPollTask = nil
    }
    accountDisconnectReason =
      if authStatus == .signedOut {
        switch state.account.lastError?.code {
        case .deviceDeleted: .deviceDeleted
        case .staleGeneration, .authenticationRequired: .sessionEnded
        default: nil
        }
      } else {
        nil
      }
    accountRefreshing = state.account.refreshing
    isLoggingIn = authStatus == .loggingIn || loginTask != nil
    isLoggingOut = authStatus == .logoutPending

    if let action = accountActionErrorMessage {
      accountErrorMessage = action
    } else if let accountError = state.account.lastError {
      accountErrorMessage = LocalServiceClientError.remote(accountError).errorDescription
    } else {
      accountErrorMessage = nil
    }

    switch incomingAuth {
    case .signedIn, .logoutPending:
      noteAccountArrived()
    case .signedOut:
      noteAccountWentAway()
    case .loggingIn, nil:
      break
    }
  }

  /// Seeds the visual fixture without going through ``acceptState``, which would fire
  /// account-arrived/went-away hooks this fixture has no coordinator for.
  func applyVisualFixture(
    authStatus: LocalServiceAuthStatus,
    accountSummary: AccountSummary?,
    displayLabel: String?,
    deviceID: String?
  ) {
    self.authStatus = authStatus
    self.accountSummary = accountSummary
    signInDisplayLabel = displayLabel
    accountDeviceID = deviceID
    accountID = accountSummary?.account.accountID
    sessionPresent = authStatus == .signedIn || authStatus == .logoutPending
    isLoggingIn = authStatus == .loggingIn
    isLoggingOut = authStatus == .logoutPending
  }

  func startLogin() {
    guard loginTask == nil, let transport else {
      if self.transport == nil { accountErrorMessage = unavailableMessage }
      return
    }
    accountActionErrorMessage = nil
    accountErrorMessage = nil
    loginAuthorizeURL = nil
    browserOpenFailed = false
    isLoggingIn = true
    loginGeneration += 1
    let generation = loginGeneration
    loginTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.loginGeneration == generation {
          isLoggingIn = !Task.isCancelled && authStatus == .loggingIn
          loginTask = nil
        }
      }
      do {
        let result = try await transport.login()
        guard self.loginGeneration == generation else { return }
        if let raw = result.authorizeURL, let url = URL(string: raw) {
          loginAuthorizeURL = url
          if !loginURLOpener.open(url) {
            browserOpenFailed = true
            let message =
              "QuotaBar could not open your browser. Copy the sign-in link and open it yourself."
            accountActionErrorMessage = message
            accountErrorMessage = message
          }
        }
        // The service stores logging_in before acknowledging this request. From here onward its
        // state/events, rather than the short-lived request task, are authoritative.
        loginTask = nil
        await onNeedsReload?()
        guard self.loginGeneration == generation else { return }
        // A cancel that landed while the request was in flight has already stopped following.
        if !Task.isCancelled {
          followLoginInProgress()
        }
      } catch is CancellationError {
        return
      } catch {
        guard self.loginGeneration == generation else { return }
        accountActionErrorMessage = Self.message(for: error)
        accountErrorMessage = accountActionErrorMessage
        await onNeedsReload?()
      }
    }
  }

  /// Keeps asking the service how the sign-in is going until it is no longer in progress.
  ///
  /// The browser round trip finishes on the service's own thread and is announced with a
  /// `state_changed` event, which is the fast path. A sign-in is the one moment the panel is
  /// waiting on exactly one event, so it also asks, on a short cadence and for a bounded time,
  /// rather than showing "finish sign-in in browser" past a sign-in that already finished.
  private func followLoginInProgress() {
    loginPollTask?.cancel()
    guard authStatus == .loggingIn else { return }
    let interval = loginPollInterval
    let deadline = ContinuousClock.now + Self.loginPollLimit
    loginPollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled, ContinuousClock.now < deadline {
        do {
          try await Task.sleep(for: interval)
        } catch {
          return
        }
        guard let self, authStatus == .loggingIn else { return }
        await onNeedsReload?()
      }
    }
  }

  /// Calls off a browser sign-in.
  ///
  /// The row keeps its Cancel until the service says the flow is over, so it is easy to press
  /// twice. A second press joins the request already in flight rather than sending the service a
  /// second `cancel_login` to race the first.
  func cancelLogin() {
    guard cancelLoginTask == nil, let transport else { return }
    loginGeneration += 1
    loginTask?.cancel()
    loginTask = nil
    loginPollTask?.cancel()
    loginPollTask = nil
    isLoggingIn = false
    accountActionErrorMessage = nil
    accountErrorMessage = nil
    loginAuthorizeURL = nil
    browserOpenFailed = false
    cancelLoginTask = Task { @MainActor [weak self] in
      defer { self?.cancelLoginTask = nil }
      do {
        try await transport.cancelLogin()
      } catch {
        let message = Self.message(for: error)
        self?.accountActionErrorMessage = message
        self?.accountErrorMessage = message
        await self?.onNeedsReload?()
      }
    }
  }

  func copyLoginLink() {
    guard let url = loginAuthorizeURL else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }

  func logout() async {
    guard !isLoggingOut, let transport else { return }
    isLoggingOut = true
    defer { isLoggingOut = false }
    accountActionErrorMessage = nil
    accountErrorMessage = nil
    do {
      _ = try await transport.logout()
      noteAccountWentAway()
      await onNeedsReload?()
    } catch is CancellationError {
      return
    } catch {
      accountActionErrorMessage = Self.message(for: error)
      accountErrorMessage = accountActionErrorMessage
      await onNeedsReload?()
    }
  }

  private func noteAccountArrived() {
    let first = !sessionPresent
    sessionPresent = true
    if first {
      onAccountArrived?(sessionEpoch)
    }
  }

  private func noteAccountWentAway() {
    guard sessionPresent else { return }
    sessionPresent = false
    sessionEpoch += 1
    onAccountWentAway?(sessionEpoch)
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
