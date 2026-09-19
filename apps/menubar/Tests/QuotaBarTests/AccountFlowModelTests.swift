import AppKit
import Foundation
import QuotaWire
import Testing

@testable import QuotaBar

@Test @MainActor
func successfulLoginCancellationDoesNotRestoreStaleLoggingInState() async throws {
  let flow = makeAccountFlow(
    client: StubLocalService(
      state: loggingInState(),
      loginDelayNanoseconds: 30_000_000_000,
      cancelDelayNanoseconds: 50_000_000
    )
  )
  flow.acceptState(loggingInState())

  flow.startLogin()
  flow.cancelLogin()
  #expect(!flow.isLoggingIn)
  try await Task.sleep(nanoseconds: 60_000_000)
  #expect(!flow.isLoggingIn)
}

/// The row keeps its Cancel until the service says the flow is over, so it is easy to press
/// twice. Two presses are one request, and a press after that one finished is a new one.
@Test @MainActor
func repeatedCancelTapsSendOneCancelLogin() async throws {
  let record = CallRecord()
  let flow = makeAccountFlow(
    client: StubLocalService(
      state: loggingInState(),
      loginDelayNanoseconds: 30_000_000_000,
      cancelDelayNanoseconds: 50_000_000,
      cancelRecord: record
    )
  )
  flow.acceptState(loggingInState())

  flow.startLogin()
  flow.cancelLogin()
  flow.cancelLogin()
  flow.cancelLogin()

  try await record.waitForCount(1)
  try await Task.sleep(for: .milliseconds(100))
  #expect(await record.count == 1, "three presses of one Cancel are one cancel_login")

  let deadline = ContinuousClock.now + .seconds(5)
  while await record.count < 2, ContinuousClock.now < deadline {
    flow.cancelLogin()
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(await record.count == 2, "a press after the first request finished is a request of its own")
}

@Test @MainActor
func loginBusyErrorStaysVisibleOverASignedOutComponentError() async throws {
  let client = StubLocalService(
    state: signedOutWithSessionEndedState(),
    loginError: .remote(LocalServiceRemoteError(code: .busy, recoveryAction: .retry))
  )
  let flow = makeAccountFlow(client: client)
  flow.acceptState(signedOutWithSessionEndedState())
  #expect(
    flow.accountErrorMessage == "The account session ended. Sign in again to continue syncing."
  )

  flow.startLogin()
  await settle {
    flow.accountErrorMessage == "The request could not be completed. Try again."
  }

  #expect(flow.accountErrorMessage == "The request could not be completed. Try again.")
  #expect(flow.accountActionErrorMessage == "The request could not be completed. Try again.")
}

@Test @MainActor
func aBrowserThatWillNotOpenKeepsSignInPendingAndOffersTheLink() async throws {
  let flow = makeAccountFlow(
    client: StubLocalService(
      state: loggingInState(),
      authorizeURL: "http://127.0.0.1/quota-login"
    ),
    loginURLOpener: AccountFlowLoginURLOpener(opens: false)
  )
  flow.acceptState(loggingInState())

  flow.startLogin()
  await settle { flow.canCopyLoginLink }

  #expect(flow.isLoggingIn)
  #expect(flow.canCopyLoginLink)
  #expect(
    flow.accountErrorMessage
      == "QuotaBar could not open your browser. Copy the sign-in link and open it yourself."
  )

  flow.copyLoginLink()
  #expect(NSPasteboard.general.string(forType: .string) == "http://127.0.0.1/quota-login")
}

@Test @MainActor
func accountActionErrorSurvivesAStateWithoutAServiceError() async throws {
  let flow = makeAccountFlow(
    client: StubLocalService(
      state: loggingInState(),
      loginDelayNanoseconds: 30_000_000_000,
      cancelFails: true
    )
  )
  flow.acceptState(loggingInState())

  flow.startLogin()
  flow.cancelLogin()
  await settle { flow.accountErrorMessage != nil }

  #expect(flow.accountErrorMessage == "QuotaBar's local service is unavailable.")
}

/// Signing in says what the account is called. The window says it too, from that moment, rather
/// than calling it "Quota account" until a whole account read has finished.
@Test @MainActor
func namesTheAccountFromTheSignInBeforeAnyAccountReadArrives() async throws {
  let flow = makeAccountFlow(client: StubLocalService(state: justSignedInState(label: "octocat")))
  flow.acceptState(justSignedInState(label: "octocat"))

  #expect(flow.accountSummary == nil)
  #expect(flow.accountDisplayLabel == "octocat")
  #expect(flow.accountState == .signedIn)
}

/// With neither a read nor a name, the window says what it honestly knows.
@Test @MainActor
func fallsBackToTheGenericAccountNameWhenTheSignInNamedNothing() async throws {
  let flow = makeAccountFlow(client: StubLocalService(state: justSignedInState(label: nil)))
  flow.acceptState(justSignedInState(label: nil))

  #expect(flow.accountDisplayLabel == "Quota account")
}

/// A sign-in finishes on the service's thread and is announced by an event. When that event does
/// not arrive, the flow still stops saying "finish sign-in in browser": it asks.
@Test @MainActor
func aSignInThatFinishedWithoutAnEventIsNoticedByThePoll() async throws {
  let service = ScriptedLocalService(
    states: [signedOutWithSessionEndedState(), loggingInState()],
    holding: justSignedInState(label: "kyledh")
  )
  let flow = AccountFlowModel(
    transport: service,
    loginPollInterval: .milliseconds(50)
  )
  flow.onNeedsReload = { [weak flow] in
    guard let flow else { return }
    do { flow.acceptState(try await service.state()) } catch {}
  }
  flow.acceptState(try await service.state())
  #expect(flow.accountState == .signedOut)

  flow.startLogin()
  #expect(try await eventually { flow.isLoggingIn })
  try await Task.sleep(for: .milliseconds(150))
  #expect(flow.isLoggingIn, "the service still answers logging_in and no event has followed")

  service.release()
  #expect(try await eventually { flow.accountState == .signedIn && !flow.isLoggingIn })
  try await Task.sleep(for: .milliseconds(100))
  let calls = service.stateCalls
  try await Task.sleep(for: .milliseconds(200))
  #expect(service.stateCalls == calls, "a finished sign-in is not followed any further")
  flow.shutdown()
}

/// Cancelling the sign-in also stops following it.
@Test @MainActor
func cancellingASignInStopsThePoll() async throws {
  let service = ScriptedLocalService(states: [
    signedOutWithSessionEndedState(),
    loggingInState(),
  ])
  let flow = AccountFlowModel(
    transport: service,
    loginPollInterval: .milliseconds(40)
  )
  flow.onNeedsReload = { [weak flow] in
    guard let flow else { return }
    do { flow.acceptState(try await service.state()) } catch {}
  }
  flow.acceptState(try await service.state())
  #expect(flow.accountState == .signedOut)
  flow.startLogin()
  #expect(try await eventually { flow.isLoggingIn })
  flow.cancelLogin()
  let deadline = ContinuousClock.now + .seconds(3)
  var calls = service.stateCalls
  var settled = false
  while !settled, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(200))
    settled = service.stateCalls == calls
    calls = service.stateCalls
  }
  #expect(settled, "state() is still being polled after Cancel")
  flow.shutdown()
}

@Test @MainActor
func aSignInResultThatLandsAfterTheFlowWasCancelledWritesNothing() async throws {
  let transport = DelayedLoginTransport(delay: .milliseconds(80))
  var reloaded = false
  let flow = AccountFlowModel(transport: transport)
  flow.onNeedsReload = { reloaded = true }

  flow.startLogin()
  flow.cancelLogin()
  try await Task.sleep(for: .milliseconds(150))

  #expect(transport.loginCalls == 1)
  #expect(flow.loginAuthorizeURL == nil)
  #expect(!flow.canCopyLoginLink)
  #expect(!flow.isLoggingIn)
  #expect(flow.accountActionErrorMessage == nil)
  #expect(flow.accountErrorMessage == nil)
  #expect(!reloaded)
}

@Test @MainActor
func signOutBumpsTheEpochAndTellsTheOtherOwners() async throws {
  let flow = makeAccountFlow(client: StubLocalService(state: justSignedInState(label: "octocat")))
  flow.acceptState(justSignedInState(label: "octocat"))
  #expect(flow.sessionEpoch == 0)
  #expect(flow.hasAccountSession)

  var usageEpoch: Int?
  var browserEpoch: Int?
  flow.onAccountWentAway = { epoch in
    usageEpoch = epoch
    browserEpoch = epoch
  }
  flow.onNeedsReload = { flow.acceptState(signedOutWithSessionEndedState()) }

  await flow.logout()

  #expect(flow.sessionEpoch == 1)
  #expect(!flow.hasAccountSession)
  #expect(usageEpoch == 1)
  #expect(browserEpoch == 1)
  #expect(flow.accountState == .signedOut)
}

@MainActor
private func makeAccountFlow(
  client: StubLocalService,
  loginURLOpener: any LoginURLOpening = WorkspaceLoginURLOpener()
) -> AccountFlowModel {
  let flow = AccountFlowModel(transport: client, loginURLOpener: loginURLOpener)
  flow.onNeedsReload = { [weak flow] in
    guard let flow else { return }
    do { flow.acceptState(try await client.state()) } catch {}
  }
  return flow
}

@MainActor
private func settle(
  within timeout: Duration = .seconds(5),
  until condition: () -> Bool
) async {
  let deadline = ContinuousClock.now + timeout
  while !condition(), ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(5))
  }
}

@MainActor
private func eventually(
  _ timeout: Duration = .seconds(3),
  _ condition: @MainActor () -> Bool
) async throws -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

private struct AccountFlowLoginURLOpener: LoginURLOpening {
  let opens: Bool

  func open(_ url: URL) -> Bool {
    opens
  }
}

private final class DelayedLoginTransport: AccountFlowTransport, @unchecked Sendable {
  let delay: Duration
  private let lock = NSLock()
  private(set) var loginCalls = 0

  init(delay: Duration) {
    self.delay = delay
  }

  func login() async throws -> LocalServiceLoginResult {
    lock.withLock { loginCalls += 1 }
    try? await Task.sleep(for: delay)
    return LocalServiceLoginResult(
      status: .loggingIn,
      accountID: nil,
      deviceID: nil,
      deviceGeneration: nil,
      authorizeURL: "http://127.0.0.1/quota-login"
    )
  }

  func cancelLogin() async throws {}

  func logout() async throws -> LocalServiceLogoutResult {
    LocalServiceLogoutResult(status: .signedOut)
  }
}
