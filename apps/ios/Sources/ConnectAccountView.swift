import SwiftUI

struct ConnectAccountView: View {
  @Bindable var model: AppModel

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        Spacer(minLength: 32)

        VStack(spacing: 24) {
          mark

          VStack(spacing: 10) {
            Text("Quota")
              .font(.largeTitle.weight(.semibold))
              .foregroundStyle(.primary)
              .accessibilityAddTraits(.isHeader)

            Text(
              "See remaining quota and Today Usage for the GitHub Account you use with QuotaBar on your Mac."
            )
            .font(.body)
            // .secondary and vibrant .primary both fail the contrast audit on the glass
            // surface; an explicit label color opts out of vibrancy.
            .foregroundStyle(Color(uiColor: .label))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
          }

          if let expired = model.expiredMessage {
            StatusBanner(
              symbolName: "lock.slash",
              text: expired
            )
          } else if let banner = model.banner {
            StatusBanner(symbolName: banner.symbolName, text: banner.text)
          }

          Button {
            Task { await model.connectAccount() }
          } label: {
            Text(model.phase == .connecting ? "Connecting…" : "Connect Account")
              .font(.headline)
              .frame(maxWidth: .infinity)
              .frame(minHeight: QuotaTheme.minimumTouchTarget - 12)
              .padding(.vertical, 6)
          }
          .quotaProminentButtonStyle()
          .disabled(model.phase == .connecting)
          .accessibilityLabel("Connect Account")
          .accessibilityHint("Opens a browser to sign in with GitHub.")

          Text("This iPhone does not collect local usage or upload snapshots.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: 420)
        .quotaSurface()

        Spacer(minLength: 48)
      }
      .frame(maxWidth: QuotaTheme.contentMaxWidth)
      .padding(.horizontal, QuotaTheme.contentGutter)
      .frame(maxWidth: .infinity)
    }
    .accessibilityIdentifier("connect.root")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var mark: some View {
    ZStack {
      Circle()
        .fill(QuotaTheme.emerald.opacity(0.16))
        .frame(width: 72, height: 72)
      Image(systemName: "gauge.with.dots.needle.33percent")
        .font(.system(size: 30, weight: .semibold))
        .foregroundStyle(QuotaTheme.emerald)
        .accessibilityHidden(true)
    }
    .accessibilityLabel("Quota")
  }
}
