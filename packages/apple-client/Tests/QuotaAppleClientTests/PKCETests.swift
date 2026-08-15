import Foundation
import QuotaAccount
import QuotaWire
import Testing

struct PKCETests {
  @Test
  func generatesS256VerifierAndOpaqueState() throws {
    let first = try PKCE.generate()
    let second = try PKCE.generate()
    #expect(WireValidation.isPKCEVerifier(first.verifier))
    #expect(first.method == "S256")
    #expect(first.verifier != second.verifier)
    #expect(first.challenge != second.challenge)

    let known = try PKCE.pair(verifier: String(repeating: "a", count: 43))
    #expect(known.challenge == "ZtNPunH49FD35FWYhT5Tv8I7vRKQJ8uxMaL0_9eHjNA")

    let stateA = try PKCE.generateState()
    let stateB = try PKCE.generateState()
    #expect(WireValidation.isClientState(stateA))
    #expect(stateA != stateB)
  }

  @Test
  func authorizationRequestUsesFixedClientAndRedirect() throws {
    let entropy = FixedEntropy(values: Array(repeating: 7, count: 64))
    let attempt = try AuthorizationRequest.make(using: entropy)
    #expect(attempt.redirectURI == QuotaIOSOAuth.redirectURI)
    let components = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)
    let queryItems = components?.queryItems ?? []
    let items = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
    #expect(attempt.authorizationURL.host == "quota.gotry.io")
    #expect(attempt.authorizationURL.scheme == "https")
    #expect(attempt.authorizationURL.path == "/oauth/v2/authorize")
    #expect(items["client_id"] == "quota-ios")
    #expect(items["redirect_uri"] == "io.gotry.quota:/oauth/callback")
    #expect(items["response_type"] == "code")
    #expect(items["code_challenge_method"] == "S256")
    #expect(items["state"] == attempt.state)
    #expect(items["code_challenge"] == attempt.challenge)
  }

  @Test
  func callbackRequiresExactRedirectAndState() throws {
    let attempt = AuthorizationAttempt(
      authorizationURL: URL(string: "https://quota.gotry.io/oauth/v2/authorize")!,
      state: "client-state-123456789",
      verifier: String(repeating: "a", count: 43),
      challenge: "challenge"
    )
    let valid = URL(
      string:
        "io.gotry.quota:/oauth/callback?code=synthetic-login-code&state=client-state-123456789"
    )!
    #expect(try OAuthCallback.parse(valid, expected: attempt) == "synthetic-login-code")

    let doubledSlash = URL(
      string:
        "io.gotry.quota://oauth/callback?code=synthetic-login-code&state=client-state-123456789"
    )!
    #expect(throws: AuthorizationError.callbackMismatch) {
      _ = try OAuthCallback.parse(doubledSlash, expected: attempt)
    }

    let wrongState = URL(
      string: "io.gotry.quota:/oauth/callback?code=synthetic-login-code&state=other-state-1234567"
    )!
    #expect(throws: AuthorizationError.stateMismatch) {
      _ = try OAuthCallback.parse(wrongState, expected: attempt)
    }

    let withToken = URL(
      string:
        "io.gotry.quota:/oauth/callback?code=synthetic-login-code&state=client-state-123456789&access_token=secret"
    )!
    #expect(throws: AuthorizationError.unexpectedCallbackToken) {
      _ = try OAuthCallback.parse(withToken, expected: attempt)
    }
  }
}
