import AuthenticationServices
import QuotaAccount
import UIKit

@MainActor
protocol BrowserSessionAuthenticating: AnyObject {
  func authenticate(
    url: URL,
    callbackScheme: String,
    prefersEphemeralWebBrowserSession: Bool
  ) async throws -> URL
  /// Present a page in `ASWebAuthenticationSession`. A nil callback scheme ends when the
  /// sheet is dismissed. Cancel is success: the person closed the session.
  func present(
    url: URL,
    callbackScheme: String?,
    prefersEphemeralWebBrowserSession: Bool
  ) async throws
}

@MainActor
final class SystemBrowserAuthenticator: NSObject, BrowserSessionAuthenticating,
  ASWebAuthenticationPresentationContextProviding
{
  private var session: ASWebAuthenticationSession?

  func authenticate(
    url: URL,
    callbackScheme: String,
    prefersEphemeralWebBrowserSession: Bool
  ) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      startSession(
        url: url,
        callbackURLScheme: callbackScheme,
        prefersEphemeralWebBrowserSession: prefersEphemeralWebBrowserSession
      ) { callback, error in
        if let error {
          let nsError = error as NSError
          if nsError.domain == ASWebAuthenticationSessionErrorDomain,
            nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
          {
            continuation.resume(throwing: AuthorizationError.cancelled)
            return
          }
          continuation.resume(throwing: error)
          return
        }
        guard let callback else {
          continuation.resume(throwing: AuthorizationError.callbackMismatch)
          return
        }
        continuation.resume(returning: callback)
      }
    }
  }

  func present(
    url: URL,
    callbackScheme: String?,
    prefersEphemeralWebBrowserSession: Bool
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      startSession(
        url: url,
        callbackURLScheme: callbackScheme,
        prefersEphemeralWebBrowserSession: prefersEphemeralWebBrowserSession
      ) { _, error in
        if let error {
          let nsError = error as NSError
          if nsError.domain == ASWebAuthenticationSessionErrorDomain,
            nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
          {
            continuation.resume()
            return
          }
          continuation.resume(throwing: error)
          return
        }
        continuation.resume()
      }
    }
  }

  private func startSession(
    url: URL,
    callbackURLScheme: String?,
    prefersEphemeralWebBrowserSession: Bool,
    completion: @escaping (URL?, Error?) -> Void
  ) {
    let session = ASWebAuthenticationSession(
      url: url,
      callbackURLScheme: callbackURLScheme
    ) { callback, error in
      self.session = nil
      completion(callback, error)
    }
    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
    self.session = session
    if !session.start() {
      self.session = nil
      completion(nil, AuthorizationError.cancelled)
    }
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
      return key
    }
    return scenes.flatMap(\.windows).first ?? ASPresentationAnchor()
  }
}
