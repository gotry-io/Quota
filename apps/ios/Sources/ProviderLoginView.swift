import QuotaProviderSessions
import QuotaWire
import SwiftUI
import WebKit

/// The provider's own sign-in page, in a web view that forgets everything but the session it
/// proves.
///
/// The store is `WKWebsiteDataStore.nonPersistent()` and is made new for each sheet, so closing
/// the sheet discards the sign-in this app did not keep. Nothing is injected into the page: no
/// user script, no message handler, no form or navigation is intercepted, and the page's content
/// is never read. What leaves this view is what the cookie store holds and the provider then
/// confirms.
@MainActor
struct ProviderLoginView: View {
  let provider: ProviderID
  let onConnected: (StoredProviderSession) -> Void

  @State private var dataStore: WKWebsiteDataStore?
  @State private var model: ProviderLoginModel?
  @Environment(\.dismiss) private var dismiss

  private let store: any ProviderSessionStoring

  init(
    provider: ProviderID,
    store: any ProviderSessionStoring,
    onConnected: @escaping (StoredProviderSession) -> Void
  ) {
    self.provider = provider
    self.store = store
    self.onConnected = onConnected
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let model, let dataStore, let url = model.loginURL {
          ProviderLoginWebView(url: url, dataStore: dataStore) {
            Task { await model.pageDidLoad() }
          }
          .accessibilityIdentifier("provider.login.web")
        } else {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        Divider()
        Text(model?.statusMessage ?? ProvidersCopy.loginStatus(.signIn, provider: provider))
          .font(.footnote)
          .foregroundStyle(.primary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)
          .padding(.vertical, 10)
          .accessibilityIdentifier("provider.login.status")
      }
      .navigationTitle(ProvidersCopy.loginTitle(provider: provider))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(ProvidersCopy.cancel) { dismiss() }
            .accessibilityIdentifier("provider.login.cancel")
        }
      }
    }
    .task {
      guard model == nil else { return }
      let dataStore = WKWebsiteDataStore.nonPersistent()
      self.dataStore = dataStore
      model = ProviderLoginModel(
        provider: provider,
        store: store,
        cookies: WebViewCookieSource(cookieStore: dataStore.httpCookieStore)
      )
    }
    .onChange(of: model?.connected) { _, session in
      guard let session else { return }
      onConnected(session)
      dismiss()
    }
    .accessibilityIdentifier("provider.login.root")
  }
}

/// The cookies the sign-in left in this sheet's own store.
@MainActor
final class WebViewCookieSource: ProviderLoginCookieSource {
  private let cookieStore: WKHTTPCookieStore

  init(cookieStore: WKHTTPCookieStore) {
    self.cookieStore = cookieStore
  }

  func cookies() async -> [BrowserCookie] {
    await cookieStore.allCookies().map {
      BrowserCookie(
        name: $0.name, value: $0.value, domain: $0.domain, expiresAt: $0.expiresDate)
    }
  }
}

/// `WKWebView` with the provider's sign-in page and nothing of this app's inside it.
struct ProviderLoginWebView: UIViewRepresentable {
  let url: URL
  let dataStore: WKWebsiteDataStore
  let didFinishNavigation: () -> Void

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.load(URLRequest(url: url))
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(didFinishNavigation: didFinishNavigation)
  }

  /// The whole delegate: a page finished loading. What the page is, and what it contains, is the
  /// provider's business.
  final class Coordinator: NSObject, WKNavigationDelegate {
    private let didFinishNavigation: () -> Void

    init(didFinishNavigation: @escaping () -> Void) {
      self.didFinishNavigation = didFinishNavigation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      didFinishNavigation()
    }
  }
}
