import CryptoKit
import Foundation
import QuotaWire
import Security

public protocol RandomBytesGenerating: Sendable {
  func bytes(count: Int) throws -> [UInt8]
}

public struct SystemRandomBytes: RandomBytesGenerating {
  public init() {}

  public func bytes(count: Int) throws -> [UInt8] {
    var values = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &values)
    guard status == errSecSuccess else {
      throw AuthorizationError.entropyUnavailable
    }
    return values
  }
}

public struct PKCEPair: Equatable, Sendable {
  public let verifier: String
  public let challenge: String
  public let method: String

  public init(verifier: String, challenge: String, method: String = "S256") {
    self.verifier = verifier
    self.challenge = challenge
    self.method = method
  }
}

public enum PKCE {
  public static func generate(using entropy: any RandomBytesGenerating = SystemRandomBytes()) throws
    -> PKCEPair
  {
    let verifier = try base64URL(entropy.bytes(count: 32))
    return try pair(verifier: verifier)
  }

  public static func pair(verifier: String) throws -> PKCEPair {
    guard WireValidation.isPKCEVerifier(verifier) else {
      throw AuthorizationError.invalidPKCE
    }
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return PKCEPair(verifier: verifier, challenge: base64URL(Array(digest)), method: "S256")
  }

  public static func generateState(using entropy: any RandomBytesGenerating = SystemRandomBytes())
    throws -> String
  {
    let state = try base64URL(entropy.bytes(count: 32))
    guard WireValidation.isClientState(state) else {
      throw AuthorizationError.invalidState
    }
    return state
  }

  static func base64URL(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

public struct AuthorizationAttempt: Sendable {
  public let authorizationURL: URL
  public let redirectURI: String
  public let state: String
  public let verifier: String
  public let challenge: String

  public init(
    authorizationURL: URL,
    redirectURI: String = QuotaIOSOAuth.redirectURI,
    state: String,
    verifier: String,
    challenge: String
  ) {
    self.authorizationURL = authorizationURL
    self.redirectURI = redirectURI
    self.state = state
    self.verifier = verifier
    self.challenge = challenge
  }
}

extension AuthorizationAttempt: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "AuthorizationAttempt(url: \(authorizationURL.absoluteString), state: [redacted])"
  }

  public var debugDescription: String { description }
}

public enum AuthorizationRequest {
  public static func make(using entropy: any RandomBytesGenerating = SystemRandomBytes()) throws
    -> AuthorizationAttempt
  {
    let pkce = try PKCE.generate(using: entropy)
    let state = try PKCE.generateState(using: entropy)
    var components = URLComponents(url: RelayOrigin.authorizeURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: QuotaIOSOAuth.clientID),
      URLQueryItem(name: "redirect_uri", value: QuotaIOSOAuth.redirectURI),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: pkce.challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    guard let url = components?.url else {
      throw AuthorizationError.invalidOrigin
    }
    return AuthorizationAttempt(
      authorizationURL: url,
      state: state,
      verifier: pkce.verifier,
      challenge: pkce.challenge
    )
  }
}

public enum OAuthCallback {
  public static func parse(_ url: URL, expected: AuthorizationAttempt) throws -> String {
    guard callbackIdentity(url) == QuotaIOSOAuth.redirectURI else {
      throw AuthorizationError.callbackMismatch
    }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let values = Dictionary(
      items.compactMap { item -> (String, String)? in
        guard let value = item.value else { return nil }
        return (item.name, value)
      },
      uniquingKeysWith: { first, _ in first }
    )
    if values["access_token"] != nil || values["refresh_token"] != nil || values["token"] != nil {
      throw AuthorizationError.unexpectedCallbackToken
    }
    guard values["state"] == expected.state else {
      throw AuthorizationError.stateMismatch
    }
    guard let code = values["code"], WireValidation.isSecret(code) else {
      throw AuthorizationError.missingAuthorizationCode
    }
    return code
  }

  public static func callbackIdentity(_ url: URL) -> String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.query = nil
    components?.fragment = nil
    return components?.string ?? url.absoluteString
  }
}

public enum AuthorizationError: Error, Equatable, Sendable {
  case entropyUnavailable
  case invalidPKCE
  case invalidState
  case invalidOrigin
  case callbackMismatch
  case stateMismatch
  case missingAuthorizationCode
  case unexpectedCallbackToken
  case cancelled
}

enum RelayOrigin {
  static let authorizeURL = URL(string: "https://quota.gotry.io/oauth/v2/authorize")!
}
