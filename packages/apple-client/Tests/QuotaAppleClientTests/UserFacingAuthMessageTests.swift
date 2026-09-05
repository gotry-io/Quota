import Foundation
import QuotaAccount
import QuotaRelay
import Testing

struct UserFacingAuthMessageTests {
  @Test
  func authorizationCallbackFailuresAskToTryAgain() {
    #expect(
      AuthorizationError.stateMismatch.userFacingMessage
        == "The browser returned an unexpected response. Try again."
    )
    #expect(
      AuthorizationError.callbackMismatch.userFacingMessage
        == "The browser returned an unexpected response. Try again."
    )
    #expect(
      AuthorizationError.missingAuthorizationCode.userFacingMessage
        == "The browser returned an unexpected response. Try again."
    )
    #expect(
      AuthorizationError.unexpectedCallbackToken.userFacingMessage
        == "The browser returned an unexpected response. Try again."
    )
  }

  @Test
  func accountClientMirrorsCallbackFailuresAndNamesReachability() {
    #expect(
      AccountClientError.stateMismatch.userFacingMessage
        == AuthorizationError.unexpectedBrowserResponseMessage
    )
    #expect(
      AccountClientError.callbackMismatch.userFacingMessage
        == AuthorizationError.unexpectedBrowserResponseMessage
    )
    #expect(
      AccountClientError.relay(.unavailable).userFacingMessage == "Couldn't reach quota.gotry.io."
    )
    #expect(
      AccountClientError.relay(.timeout).userFacingMessage == "Couldn't reach quota.gotry.io."
    )
    #expect(
      AccountClientError.relay(.invalidGrant).userFacingMessage
        == AuthorizationError.expiredSignInMessage
    )
    #expect(
      AccountClientError.relay(.rejected(code: "invalid_grant", status: 400)).userFacingMessage
        == AuthorizationError.expiredSignInMessage
    )
    #expect(
      AccountClientError.accountMismatch.userFacingMessage
        == AuthorizationError.genericConnectFailureMessage
    )
  }
}
