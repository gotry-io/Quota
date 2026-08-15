import SwiftUI

private struct QuotaPageTransitionActiveKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var quotaPageTransitionActive: Bool {
    get { self[QuotaPageTransitionActiveKey.self] }
    set { self[QuotaPageTransitionActiveKey.self] = newValue }
  }
}

/// Holds a page's immutable presentation while its route is moving on or off screen.
/// Data work continues and repeated updates are coalesced into the latest pending value.
struct QuotaNavigationPresentationBuffer<Value: Equatable>: Equatable {
  private(set) var displayed: Value
  private(set) var pending: Value?

  init(_ state: Value) {
    displayed = state
  }

  mutating func receive(_ state: Value, transitionActive: Bool) {
    if transitionActive {
      pending = state == displayed ? nil : state
    } else {
      displayed = state
      pending = nil
    }
  }

  mutating func finishTransition(latest state: Value) {
    displayed = pending ?? state
    pending = nil
  }
}

/// Shared page host for state-driven roots. It prevents loading/error/content replacement from
/// mutating a page midway through a navigation transition.
struct QuotaNavigationStableContent<Value: Equatable, Content: View>: View {
  let state: Value
  let content: (Value) -> Content

  @Environment(\.quotaPageTransitionActive) private var transitionActive
  @State private var presentation: QuotaNavigationPresentationBuffer<Value>

  init(state: Value, @ViewBuilder content: @escaping (Value) -> Content) {
    self.state = state
    self.content = content
    _presentation = State(initialValue: QuotaNavigationPresentationBuffer(state))
  }

  var body: some View {
    content(transitionActive ? presentation.displayed : state)
      .onChange(of: state) { _, next in
        updateWithoutAnimation {
          presentation.receive(next, transitionActive: transitionActive)
        }
      }
      .onChange(of: transitionActive) { _, isActive in
        guard !isActive else { return }
        updateWithoutAnimation {
          presentation.finishTransition(latest: state)
        }
      }
  }

  private func updateWithoutAnimation(_ update: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, update)
  }
}

/// Content-only presentation for a page that has no useful body to show yet.
enum QuotaPageStatePresentation: Equatable {
  case loading(title: String)
  case empty(systemImage: String, title: String, message: String)
  case error(title: String, message: String)

  var accessibilityLabel: String {
    switch self {
    case .loading(let title):
      title
    case .empty(_, let title, let message):
      "\(title). \(message)"
    case .error(let title, let message):
      "Error: \(title). \(message)"
    }
  }
}

/// Centered body state used only when a page has no content worth preserving.
struct QuotaPageStateView: View {
  let presentation: QuotaPageStatePresentation
  private let actionTitle: String?
  private let action: (() -> Void)?

  init(loadingTitle title: String) {
    presentation = .loading(title: title)
    actionTitle = nil
    action = nil
  }

  init(emptySystemImage systemImage: String, title: String, message: String) {
    presentation = .empty(systemImage: systemImage, title: title, message: message)
    actionTitle = nil
    action = nil
  }

  init(
    emptySystemImage systemImage: String,
    title: String,
    message: String,
    actionTitle: String,
    action: @escaping () -> Void
  ) {
    presentation = .empty(systemImage: systemImage, title: title, message: message)
    self.actionTitle = actionTitle
    self.action = action
  }

  init(errorTitle title: String, message: String, retry: @escaping () -> Void) {
    presentation = .error(title: title, message: message)
    actionTitle = "Retry"
    action = retry
  }

  var body: some View {
    VStack(spacing: QuotaDesign.Spacing.sectionBody) {
      stateContent
        .frame(maxWidth: QuotaDesign.Layout.emptyStateContentMaxWidth)

      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(QuotaPrimaryButtonStyle(isCompact: true))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(.horizontal, QuotaDesign.Layout.emptyStateHorizontalPadding)
    .padding(.vertical, QuotaDesign.Layout.emptyStateVerticalPadding)
  }

  @ViewBuilder
  private var stateContent: some View {
    switch presentation {
    case .loading(let title):
      VStack(spacing: QuotaDesign.Spacing.sm) {
        ProgressView()
          .controlSize(.small)
        Text(title)
          .quotaSecondaryStyle()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(presentation.accessibilityLabel)

    case .empty(let systemImage, let title, let message):
      messageContent(
        systemImage: systemImage,
        title: title,
        message: message,
        color: QuotaPalette.body
      )

    case .error(let title, let message):
      messageContent(
        systemImage: "exclamationmark.circle",
        title: title,
        message: message,
        color: QuotaPalette.critical
      )
    }
  }

  private func messageContent(
    systemImage: String,
    title: String,
    message: String,
    color: Color
  ) -> some View {
    VStack(spacing: QuotaDesign.Spacing.sm) {
      Image(systemName: systemImage)
        .font(QuotaDesign.Typography.emptyIcon)
        .foregroundStyle(color)
        .accessibilityHidden(true)

      Text(title)
        .quotaEmptyTitleStyle()

      Text(message)
        .quotaSecondaryStyle()
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.accessibilityLabel)
  }
}

enum QuotaNoticeTone: Equatable {
  case warning
  case error

  var systemImage: String {
    switch self {
    case .warning: "exclamationmark.triangle.fill"
    case .error: "exclamationmark.circle.fill"
    }
  }

  var accessibilityPrefix: String {
    switch self {
    case .warning: "Warning"
    case .error: "Error"
    }
  }
}

/// A compact warning shown above content that remains useful after a failed refresh.
struct QuotaInlineNotice: View {
  let message: String
  var tone: QuotaNoticeTone = .warning

  var accessibilityLabel: String {
    "\(tone.accessibilityPrefix): \(message)"
  }

  var body: some View {
    HStack(alignment: .top, spacing: QuotaDesign.Spacing.sm) {
      Image(systemName: tone.systemImage)
        .quotaFont(.secondary)
        .foregroundStyle(tone == .warning ? QuotaPalette.warning : QuotaPalette.critical)
        .frame(width: QuotaDesign.Layout.settingsIconColumnWidth)
        .accessibilityHidden(true)

      Text(message)
        .quotaListSecondaryStyle()
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .padding(.vertical, QuotaDesign.Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaGroupSurface()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }
}

enum QuotaSectionStatePresentation: Equatable {
  case loading(title: String)
  case empty(message: String)
  case error(message: String)

  var accessibilityLabel: String {
    switch self {
    case .loading(let title): title
    case .empty(let message): message
    case .error(let message): "Error: \(message)"
    }
  }
}

/// A left-aligned state scoped to one section while surrounding page controls remain available.
struct QuotaSectionStateView: View {
  let presentation: QuotaSectionStatePresentation

  var body: some View {
    HStack(alignment: .top, spacing: QuotaDesign.Spacing.sm) {
      sectionIcon

      Text(text)
        .quotaListSecondaryStyle()
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .padding(.vertical, QuotaDesign.Layout.settingsRowVerticalPadding)
    .frame(
      maxWidth: .infinity,
      minHeight: QuotaDesign.Layout.settingsRowHeight,
      alignment: .leading
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.accessibilityLabel)
  }

  @ViewBuilder
  private var sectionIcon: some View {
    switch presentation {
    case .loading:
      ProgressView()
        .controlSize(.mini)
        .frame(width: QuotaDesign.Layout.settingsIconColumnWidth)
        .accessibilityHidden(true)
    case .empty:
      Image(systemName: "minus.circle")
        .quotaFont(.secondary)
        .foregroundStyle(QuotaPalette.mute)
        .frame(width: QuotaDesign.Layout.settingsIconColumnWidth)
        .accessibilityHidden(true)
    case .error:
      Image(systemName: "exclamationmark.circle.fill")
        .quotaFont(.secondary)
        .foregroundStyle(QuotaPalette.critical)
        .frame(width: QuotaDesign.Layout.settingsIconColumnWidth)
        .accessibilityHidden(true)
    }
  }

  private var text: String {
    switch presentation {
    case .loading(let title): title
    case .empty(let message), .error(let message): message
    }
  }
}
