import AppKit
import SwiftUI

struct QuotaChoiceMenuOption: Identifiable, Equatable {
  /// `nil` is Automatic.
  let pin: String?
  let title: String
  /// One quiet line under the title, for the option whose meaning is not its name.
  var subtitle: String? = nil

  var id: String { pin ?? "automatic" }
}

/// Compact trailing menu using the panel's floating surface, not a system `Menu`.
struct QuotaChoiceMenu: View {
  let valueTitle: String
  let options: [QuotaChoiceMenuOption]
  let selectedPin: String?
  @Binding var isExpanded: Bool
  let onSelect: (String?) -> Void
  let accessibilityTitle: String
  let accessibilityHint: String

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isTriggerFocused: Bool
  @State private var triggerWindowFrame = CGRect.zero
  @State private var listWindowFrame = CGRect.zero

  var body: some View {
    VStack(alignment: .trailing, spacing: 0) {
      Button {
        toggleExpanded()
      } label: {
        HStack(spacing: QuotaDesign.Spacing.xxs) {
          Text(valueTitle)
            .quotaFont(.meta)
            .foregroundStyle(QuotaPalette.body)
            .lineLimit(1)
          Image(systemName: "chevron.down")
            .quotaAffordanceStyle()
        }
        .padding(.horizontal, QuotaDesign.Spacing.xs)
        .frame(height: QuotaDesign.Layout.headerControlSurfaceSize)
        .background {
          RoundedRectangle(cornerRadius: QuotaDesign.Layout.rowCornerRadius, style: .continuous)
            .fill(QuotaPalette.fieldFill)
        }
        .frame(minHeight: QuotaDesign.Layout.minimumInteractiveDimension)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable()
      .focused($isTriggerFocused)
      .accessibilityLabel(accessibilityTitle)
      .accessibilityHint(accessibilityHint)
      .onKeyPress(.upArrow) {
        setExpanded(true)
        return .handled
      }
      .onKeyPress(.downArrow) {
        setExpanded(true)
        return .handled
      }
      .background {
        WindowFrameReader { triggerWindowFrame = $0 }
      }
    }
    .overlay(alignment: .topTrailing) {
      if isExpanded {
        menuList
          .padding(.top, QuotaDesign.Layout.minimumInteractiveDimension + QuotaDesign.Spacing.xxs)
          .background {
            WindowFrameReader { listWindowFrame = $0 }
          }
      }
    }
    .background {
      OutsideClickMonitor(
        isEnabled: isExpanded,
        triggerFrame: triggerWindowFrame,
        listFrame: isExpanded ? listWindowFrame : .zero
      ) {
        setExpanded(false)
      }
    }
    .zIndex(isExpanded ? 10 : 0)
    .onExitCommand {
      if isExpanded { setExpanded(false) }
    }
  }

  private var menuList: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(options) { option in
        Button {
          onSelect(option.pin)
          setExpanded(false)
        } label: {
          HStack(spacing: QuotaDesign.Spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
              Text(option.title)
                .quotaSettingsLabelStyle()
                .lineLimit(1)
              if let subtitle = option.subtitle {
                Text(subtitle)
                  .quotaListSecondaryStyle()
                  .lineLimit(1)
              }
            }
            Spacer(minLength: QuotaDesign.Spacing.sm)
            Image(systemName: "checkmark")
              .quotaFont(.secondary)
              .foregroundStyle(QuotaPalette.accent)
              .opacity(option.pin == selectedPin ? 1 : 0)
              .accessibilityHidden(true)
          }
          .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
          .frame(minHeight: QuotaDesign.Layout.fieldMinHeight)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(
          QuotaListRowButtonStyle(cornerRadius: QuotaDesign.Layout.floatingMenuRowCornerRadius)
        )
        .accessibilityLabel(option.subtitle.map { "\(option.title). \($0)" } ?? option.title)
        .accessibilityValue(option.pin == selectedPin ? "Selected" : "")
        .accessibilityAddTraits(option.pin == selectedPin ? .isSelected : [])
      }
    }
    .frame(minWidth: 160, maxWidth: QuotaDesign.Layout.headerMenuWidth)
    .padding(QuotaDesign.Layout.groupSurfaceInset)
    .quotaFloatingMenuSurface()
    .accessibilityLabel(accessibilityTitle)
  }

  private func toggleExpanded() {
    setExpanded(!isExpanded)
  }

  private func setExpanded(_ expanded: Bool) {
    if expanded {
      isTriggerFocused = true
    }
    if reduceMotion {
      isExpanded = expanded
    } else {
      withAnimation(expanded ? .easeOut(duration: 0.12) : .easeIn(duration: 0.08)) {
        isExpanded = expanded
      }
    }
  }
}

/// Reports this view's bounds in window coordinates for hit-testing.
private struct WindowFrameReader: NSViewRepresentable {
  var onChange: (CGRect) -> Void

  func makeNSView(context: Context) -> FrameView {
    let view = FrameView()
    view.onChange = onChange
    return view
  }

  func updateNSView(_ nsView: FrameView, context: Context) {
    nsView.onChange = onChange
  }

  final class FrameView: NSView {
    var onChange: ((CGRect) -> Void)?
    private var lastReported: CGRect?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
      super.layout()
      report()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      report()
    }

    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      report()
    }

    func report() {
      guard window != nil else { return }
      let rect = convert(bounds, to: nil)
      guard lastReported != rect else { return }
      lastReported = rect
      DispatchQueue.main.async { [weak self] in
        self?.onChange?(rect)
      }
    }
  }
}

/// Dismisses the floating menu when a click lands outside the trigger and list.
private struct OutsideClickMonitor: NSViewRepresentable {
  var isEnabled: Bool
  var triggerFrame: CGRect
  var listFrame: CGRect
  var onOutsideClick: () -> Void

  func makeNSView(context: Context) -> MonitorView {
    let view = MonitorView()
    view.isEnabled = isEnabled
    view.triggerFrame = triggerFrame
    view.listFrame = listFrame
    view.onOutsideClick = onOutsideClick
    view.syncMonitor()
    return view
  }

  func updateNSView(_ nsView: MonitorView, context: Context) {
    nsView.isEnabled = isEnabled
    nsView.triggerFrame = triggerFrame
    nsView.listFrame = listFrame
    nsView.onOutsideClick = onOutsideClick
    nsView.syncMonitor()
  }

  static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
    nsView.stop()
  }

  final class MonitorView: NSView {
    var isEnabled = false
    var triggerFrame = CGRect.zero
    var listFrame = CGRect.zero
    var onOutsideClick: (() -> Void)?
    private var monitor: Any?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func syncMonitor() {
      if isEnabled {
        start()
      } else {
        stop()
      }
    }

    func start() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
        [weak self] event in
        guard let self, self.isEnabled else { return event }
        if !self.isInsideProtectedArea(event) {
          DispatchQueue.main.async {
            self.onOutsideClick?()
          }
        }
        return event
      }
    }

    func stop() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
    }

    private func isInsideProtectedArea(_ event: NSEvent) -> Bool {
      guard event.window === window else { return false }
      let point = event.locationInWindow
      let slop = QuotaDesign.Spacing.xxs
      let trigger = triggerFrame.insetBy(dx: -slop, dy: -slop)
      return trigger.contains(point) || listFrame.contains(point)
    }
  }
}
