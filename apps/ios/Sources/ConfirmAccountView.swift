import SwiftUI

struct ConfirmAccountView: View {
  @Bindable var model: AppModel
  let label: String

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 24) {
          QuotaAppMark()

          Text("Use this GitHub account?")
            .font(.title2.weight(.semibold))
            .foregroundStyle(Color(uiColor: .label))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)

          Text(connectedAs)
            .font(.body)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

          Button {
            Task { await model.confirmAccount() }
          } label: {
            Text("Continue")
              .font(.headline)
              .frame(maxWidth: .infinity)
              .frame(minHeight: 50)
          }
          .buttonStyle(.glassProminent)
          .accessibilityLabel("Continue")
          .accessibilityHint("Use this GitHub account on this iPhone.")
          .accessibilityIdentifier("confirm.continue")

          Button {
            Task { await model.useDifferentAccount() }
          } label: {
            Text("Use a different account")
              .frame(maxWidth: .infinity)
              .frame(minHeight: QuotaTheme.minimumTouchTarget)
          }
          .buttonStyle(.bordered)
          .accessibilityLabel("Use a different account")
          .accessibilityHint("Signs out and opens GitHub so you can pick another account.")
          .accessibilityIdentifier("confirm.switch")
        }
        .frame(maxWidth: 320)
        .padding()
        .frame(minHeight: proxy.size.height)
        .frame(maxWidth: .infinity)
      }
    }
    .safeAreaPadding()
    .background(Color(uiColor: .systemBackground))
    .accessibilityIdentifier("confirm.root")
  }

  private var connectedAs: AttributedString {
    var prefix = AttributedString("Connected as ")
    prefix.foregroundColor = UIColor.label
    var name = AttributedString(label)
    name.inlinePresentationIntent = .stronglyEmphasized
    name.foregroundColor = UIColor.label
    var suffix = AttributedString(".")
    suffix.foregroundColor = UIColor.label
    prefix.append(name)
    prefix.append(suffix)
    return prefix
  }
}
