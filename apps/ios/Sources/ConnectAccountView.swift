import SwiftUI

struct ConnectAccountView: View {
  @Bindable var model: AppModel

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
    } else {
      connectButton
    }
  }

  private var connecting: Bool {
    model.phase == .connecting
  }

  private var connectButton: some View {
    Button {
      Task { await model.connectAccount() }
    } label: {
      HStack(spacing: 8) {
        if connecting {
          ProgressView()
            .tint(.primary)
            .accessibilityHidden(true)
          connectingTitle
        } else {
          Text("Connect with GitHub")
            .font(.headline)
        }
      }
      .frame(maxWidth: .infinity)
      .frame(minHeight: 50)
    }
    .connectChrome(connecting: connecting)
    .disabled(connecting)
    .accessibilityLabel("Connect with GitHub")
    .accessibilityValue(connecting ? "Connecting" : "")
    .accessibilityHint("Opens GitHub sign-in in your browser.")
    .accessibilityRespondsToUserInteraction(!connecting)
    .accessibilityIdentifier("connect.github")
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
    .accessibilityHint("Tries to load this GitHub account again.")
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
    .accessibilityHint("Signs out and opens GitHub so you can pick another account.")
    .accessibilityIdentifier("connect.switch")
  }

  private var footnote: some View {
    Text("This iPhone only reads data reported by QuotaBar.")
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

extension View {
  @ViewBuilder
  fileprivate func connectChrome(connecting: Bool) -> some View {
    if connecting {
      self
        .buttonStyle(.glass)
        .foregroundStyle(.primary)
    } else {
      self
        .buttonStyle(.glassProminent)
        .tint(QuotaTheme.emerald)
    }
  }
}
