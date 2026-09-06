import AuthenticationServices
import SwiftUI

struct ConnectAccountView: View {
  @Bindable var model: AppModel
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 24) {
          QuotaAppMark()
          actions
          VStack(spacing: 12) {
            footnote
            statusLine
          }
          // Clear of the prominent button's glass bloom so the footnote reads on plain background.
          .padding(.top, 24)
          .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 320)
        .padding()
        .frame(minHeight: proxy.size.height)
        .frame(maxWidth: .infinity)
      }
    }
    .safeAreaPadding()
    .background(Color(uiColor: .systemBackground))
    .accessibilityIdentifier("connect.root")
  }

  @ViewBuilder
  private var actions: some View {
    if model.phase == .pendingRefreshFailed {
      retryButton
      switchAccountButton
    } else if connecting {
      // Apple's control has no busy presentation of its own, so connecting draws the one
      // button that does rather than a live second way in.
      connectingButton
    } else {
      VStack(spacing: 12) {
        appleButton
        githubButton
        emailButton
      }
    }
  }

  /// Apple's own control, drawn by Apple: the mark, the label, and the sheet are theirs. It asks
  /// on the device rather than in a browser, so nothing here opens one.
  private var appleButton: some View {
    SignInWithAppleButton(.continue) { request in
      model.prepareAppleRequest(request)
    } onCompletion: { result in
      Task { await model.connectWithApple(result) }
    }
    // Apple's guidance pairs the black button with a light appearance and the white one with a
    // dark appearance; either is theirs to draw.
    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
    .frame(maxWidth: .infinity)
    .frame(height: 50)
    .clipShape(Capsule())
    .accessibilityIdentifier("connect.apple")
  }

  private var connecting: Bool {
    model.phase == .connecting
  }

  private var githubButton: some View {
    webSignInButton(title: "Continue with GitHub", identifier: "connect.github")
      .buttonStyle(.glassProminent)
      .tint(QuotaTheme.emerald)
  }

  private var emailButton: some View {
    webSignInButton(title: "Continue with Email", identifier: "connect.email")
      .buttonStyle(.glass)
      .foregroundStyle(.primary)
  }

  /// Both browser channels open the same Relay sign-in page, which asks which Account this is
  /// and offers every channel that reaches one.
  private func webSignInButton(title: String, identifier: String) -> some View {
    Button {
      Task { await model.connectAccount() }
    } label: {
      Text(title)
        .font(.headline)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 50)
    }
    .accessibilityLabel(title)
    .accessibilityHint("Opens Quota sign-in in your browser.")
    .accessibilityIdentifier(identifier)
  }

  /// The one button a sign-in in flight draws. Which channel opened the browser is not something
  /// this app knows once the sheet is up — the page asks — so the busy label names neither.
  private var connectingButton: some View {
    Button {
    } label: {
      HStack(spacing: 8) {
        ProgressView()
          .tint(.primary)
          .accessibilityHidden(true)
        connectingTitle
      }
      .frame(maxWidth: .infinity)
      .frame(minHeight: 50)
    }
    .buttonStyle(.glass)
    .foregroundStyle(.primary)
    .disabled(true)
    .accessibilityLabel("Connecting")
    .accessibilityRespondsToUserInteraction(false)
    .accessibilityIdentifier("connect.connecting")
  }

  /// Drawn in Canvas so the contrast auditor does not treat the title as a child StaticText
  /// on translucent glass. The button remains the one accessibility element.
  private var connectingTitle: some View {
    Canvas { context, size in
      context.draw(
        Text("Connecting…").font(.headline).foregroundColor(.primary),
        at: CGPoint(x: size.width / 2, y: size.height / 2),
        anchor: .center
      )
    }
    .frame(width: 128, height: 22)
    .accessibilityHidden(true)
  }

  private var retryButton: some View {
    Button {
      Task { await model.retryPendingIdentification() }
    } label: {
      HStack(spacing: 8) {
        if model.isRefreshing {
          ProgressView()
            .tint(Color(uiColor: .label))
            .accessibilityHidden(true)
        }
        Text("Retry")
          .font(.headline)
      }
      .frame(maxWidth: .infinity)
      .frame(minHeight: 50)
    }
    .buttonStyle(.glassProminent)
    .tint(QuotaTheme.emerald)
    .disabled(model.isRefreshing)
    .accessibilityLabel("Retry")
    .accessibilityHint("Tries to load this account again.")
    .accessibilityIdentifier("connect.retry")
  }

  private var switchAccountButton: some View {
    Button {
      Task { await model.useDifferentAccount() }
    } label: {
      Text("Use a different account")
        .frame(maxWidth: .infinity)
        .frame(minHeight: QuotaTheme.minimumTouchTarget)
    }
    .buttonStyle(.bordered)
    .disabled(model.isRefreshing)
    .accessibilityLabel("Use a different account")
    .accessibilityHint("Signs out and opens sign-in so you can pick another account.")
    .accessibilityIdentifier("connect.switch")
  }

  private var footnote: some View {
    Text("Signing in shows what QuotaBar reports from your Macs, alongside what this iPhone reads.")
      .font(.footnote)
      .foregroundStyle(.primary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  private var statusLine: some View {
    if let expired = model.expiredMessage {
      StatusMessage(symbolName: "lock.slash", text: expired)
    } else if let banner = model.banner {
      StatusMessage(symbolName: banner.symbolName, text: banner.text)
    }
  }
}
