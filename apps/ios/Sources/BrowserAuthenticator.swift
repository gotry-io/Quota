import AuthenticationServices
import QuotaAccount
import UIKit

@MainActor
protocol BrowserSessionAuthenticating: AnyObject {
  func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

@MainActor
final class SystemBrowserAuthenticator: NSObject, BrowserSessionAuthenticating,
  ASWebAuthenticationPresentationContextProviding
{
  private var session: ASWebAuthenticationSession?

  func authenticate(url: URL, callbackScheme: String) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(
        url: url,
        callbackURLScheme: callbackScheme
      ) { callback, error in
        self.session = nil
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
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = true
      self.session = session
      if !session.start() {
        self.session = nil
        continuation.resume(throwing: AuthorizationError.cancelled)
      }
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
