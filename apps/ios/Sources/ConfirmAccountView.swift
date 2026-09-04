import SwiftUI

struct ConfirmAccountView: View {
  @Bindable var model: AppModel
  let label: String

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        Spacer(minLength: 32)

        VStack(spacing: 24) {
          mark

          VStack(spacing: 10) {
            Text("Use this GitHub account?")
              .font(.title2.weight(.semibold))
              .foregroundStyle(.primary)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityAddTraits(.isHeader)

            (Text("Connected as ") + Text(label).bold() + Text("."))
              .font(.body)
              .foregroundStyle(Color(uiColor: .label))
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }

          Button {
            model.confirmAccount()
          } label: {
            Text("Continue")
              .font(.headline)
              .frame(maxWidth: .infinity)
              .frame(minHeight: QuotaTheme.minimumTouchTarget - 12)
              .padding(.vertical, 6)
          }
          .quotaProminentButtonStyle()
          .accessibilityLabel("Continue")
          .accessibilityHint("Use this GitHub account on this iPhone.")
          .accessibilityIdentifier("confirm.continue")

          Button {
            Task { await model.useDifferentAccount() }
          } label: {
            Text("Use a different account")
              .font(.body.weight(.semibold))
              .frame(maxWidth: .infinity)
              .frame(minHeight: QuotaTheme.minimumTouchTarget)
          }
          .foregroundStyle(.primary)
          .accessibilityLabel("Use a different account")
          .accessibilityHint("Signs out and opens GitHub so you can pick another account.")
          .accessibilityIdentifier("confirm.switch")
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
    .accessibilityIdentifier("confirm.root")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var mark: some View {
    ZStack {
      Circle()
        .fill(QuotaTheme.emerald.opacity(0.16))
        .frame(width: 72, height: 72)
      Image(systemName: "person.crop.circle.badge.checkmark")
        .font(.system(size: 30, weight: .semibold))
        .foregroundStyle(QuotaTheme.emerald)
        .accessibilityHidden(true)
    }
    .accessibilityLabel("Quota")
  }
}
