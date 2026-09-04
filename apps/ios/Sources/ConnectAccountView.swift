import SwiftUI

struct ConnectAccountView: View {
  @Bindable var model: AppModel

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 24) {
          mark
          connectButton
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

  private var connectButton: some View {
    Button {
      Task { await model.connectAccount() }
    } label: {
      HStack(spacing: 8) {
        if model.phase == .connecting {
          ProgressView()
            .accessibilityHidden(true)
        }
        Text(model.phase == .connecting ? "Connecting…" : "Connect with GitHub")
          .font(.headline)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity)
      .frame(minHeight: 50)
    }
    .buttonStyle(.glassProminent)
    .tint(QuotaTheme.emerald)
    .disabled(model.phase == .connecting)
    .accessibilityLabel("Connect with GitHub")
    .accessibilityHint("Opens GitHub sign-in in your browser.")
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

  private var mark: some View {
    Image(systemName: "gauge.with.dots.needle.33percent")
      .font(.system(size: 28, weight: .semibold))
      .foregroundStyle(QuotaTheme.emerald)
      .frame(width: 56, height: 56)
      .accessibilityLabel("Quota")
      .accessibilityAddTraits(.isImage)
  }
}
