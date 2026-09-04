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
          .padding(.top, 8)
          .frame(maxWidth: .infinity)
          .background(Color(uiColor: .systemBackground))
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
            .tint(Color(uiColor: .label))
            .accessibilityHidden(true)
        }
        Group {
          if connecting {
            Text("Connecting…")
              .font(.headline)
              .foregroundStyle(Color(uiColor: .label))
          } else {
            Text("Connect with GitHub")
              .font(.headline)
          }
        }
        .accessibilityHidden(true)
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
      .foregroundStyle(Color(uiColor: .label))
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

  private func statusLabel(text: String, symbolName: String) -> some View {
    Label {
      Text(text)
        .foregroundStyle(Color(uiColor: .label))
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: symbolName)
        .foregroundStyle(Color(uiColor: .label))
    }
    .font(.subheadline)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

extension View {
  @ViewBuilder
  fileprivate func connectChrome(connecting: Bool) -> some View {
    if connecting {
      self
        .buttonStyle(.glass)
        .foregroundStyle(Color(uiColor: .label))
    } else {
      self
        .buttonStyle(.glassProminent)
        .tint(QuotaTheme.emerald)
    }
  }
}
