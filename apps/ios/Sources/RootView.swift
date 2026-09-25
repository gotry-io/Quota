import SwiftUI

enum RootPhaseTransition {
  static func animation(reduceMotion: Bool) -> Animation {
    reduceMotion ? .easeInOut(duration: 0.15) : .default
  }
}

struct RootView: View {
  @Bindable var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The launch mark over the first frame. Visual fixtures start without it.
  @State private var showsLaunchMark: Bool

  init(model: AppModel) {
    self.model = model
    #if DEBUG
      _showsLaunchMark = State(
        initialValue: !model.skipsRestore || model.posedLaunchProgress != nil)
    #else
      _showsLaunchMark = State(initialValue: true)
    #endif
  }

  var body: some View {
    ZStack {
      surfaceContent
        .id(surface)
        .transition(.opacity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(RootPhaseTransition.animation(reduceMotion: reduceMotion), value: surface)
    .overlay {
      if showsLaunchMark {
        LaunchMarkOverlay(
          isReady: model.hasRestoredLocalState,
          posedProgress: posedLaunchProgress,
          onFinish: { showsLaunchMark = false }
        )
      }
    }
  }

  private var posedLaunchProgress: Double? {
    #if DEBUG
      model.posedLaunchProgress
    #else
      nil
    #endif
  }

  /// What owns the screen. Launching, signed out and signed in are one surface — the tabs — so
  /// restoring the session does not rebuild them; only a sign-in in flight replaces them.
  private enum Surface: Hashable {
    case tabs
    case connect
    case confirm(label: String)
  }

  private var surface: Surface {
    switch model.phase {
    case .launching, .signedOut, .signedIn: .tabs
    case .connecting, .pendingRefreshFailed: .connect
    case .confirmingAccount(let label): .confirm(label: label)
    }
  }

  @ViewBuilder
  private var surfaceContent: some View {
    switch surface {
    case .tabs:
      signedInTabs
    // A sign-in in flight owns the screen, because it is a question waiting for an answer.
    case .connect:
      ConnectAccountView(model: model)
    case .confirm(let label):
      ConfirmAccountView(model: model, label: label)
    }
  }

  private var signedInTabs: some View {
    TabView(selection: $model.selectedTab) {
      Tab(AppTab.quota.title, systemImage: AppTab.quota.systemImage, value: AppTab.quota) {
        NavigationStack(path: $model.overviewPath) {
          OverviewView(model: model)
            .navigationDestination(for: String.self) { key in
              if let subscription = model.subscription(forKey: key) {
                SubscriptionDetailView(
                  subscription: subscription,
                  deviceNames: model.readingDeviceNames,
                  samples: model.localSamples,
                  historySync: model.accountSettings.historySync == true,
                  accountSamples: model.quotaHistory.samplesBySubscription[subscription.key]
                )
                .task(id: "\(subscription.key)|\(model.accountSettings.historySync == true)") {
                  await model.loadAccountQuotaHistory(for: subscription)
                }
              }
            }
        }
      }

      Tab(AppTab.usage.title, systemImage: AppTab.usage.systemImage, value: AppTab.usage) {
        NavigationStack(path: $model.usagePath) {
          UsageView(model: model)
            .navigationDestination(for: UsageDestination.self) { destination in
              switch destination {
              case .breakdown:
                UsageBreakdownDestination(model: model)
              case .patterns:
                UsagePatternsView(model: model)
              }
            }
        }
      }

      Tab(AppTab.settings.title, systemImage: AppTab.settings.systemImage, value: AppTab.settings) {
        NavigationStack(path: $model.settingsPath) {
          SettingsView(model: model)
        }
      }
    }
    .tabBarMinimizeBehavior(.onScrollDown)
    // Signing in is a question asked over the tabs, not a wall in front of them: this phone is
    // showing what it read for itself either way
    // ([ADR 0034](../../../docs/decisions/0034-ios-collects-for-itself.md)). It hangs on the
    // TabView rather than the phase switch above it, because a presentation attached outside the
    // TabView stops the iOS 26 tab bar re-expanding when a list is scrolled back up.
    .sheet(isPresented: $model.presentsSignIn) {
      ConnectAccountView(model: model)
        .presentationDragIndicator(.visible)
    }
  }
}

/// The Quota mark over the first frame: the whole mark as a faint track, the ring filling along
/// it, then a slight scale-up as it fades into the tabs.
///
/// It is the continuation of the system launch screen (`UILaunchScreen`: `LaunchBackground` and
/// the 108-point `LaunchMark`, which is this track pre-blended onto that background, centred on
/// the whole screen), drawn at the same size in the same place, so the handover from the system
/// to the app neither moves nor changes colour. It waits for the local cache
/// restore — the first content — and never for the network, and it never waits longer than `cap`
/// whatever restore is doing. With Reduce Motion the mark is whole from the start, does not
/// scale, and only fades. It is decoration: VoiceOver never lands on it and it takes no touches.
struct LaunchMarkOverlay: View {
  /// The local cache has been read.
  let isReady: Bool
  /// A visual fixture holds the mark still at this much of its fill.
  var posedProgress: Double?
  /// Called once the overlay has faded out, to take it out of the hierarchy.
  let onFinish: () -> Void

  static let fillSeconds = 0.45
  static let fill: Duration = .seconds(fillSeconds)
  static let cap: Duration = .milliseconds(800)
  static let exit: Double = 0.22
  static let exitScale: CGFloat = 1.06
  static let trackOpacity: Double = 0.18

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var progress: Double = 0
  @State private var isFilled = false
  @State private var isLeaving = false

  var body: some View {
    ZStack {
      Color("LaunchBackground")
      ZStack {
        QuotaMarkDrawing(progress: 1)
          .opacity(Self.trackOpacity)
        QuotaMarkDrawing(progress: posedProgress ?? (reduceMotion ? 1 : progress))
      }
      .foregroundStyle(QuotaTheme.emerald)
      .frame(
        width: QuotaDesign.Layout.quotaMarkLaunch,
        height: QuotaDesign.Layout.quotaMarkLaunch
      )
      .scaleEffect(isLeaving && !reduceMotion ? Self.exitScale : 1)
    }
    // Centred on the whole screen, as the system launch screen centres its image.
    .ignoresSafeArea()
    .opacity(isLeaving ? 0 : 1)
    .accessibilityHidden(true)
    .allowsHitTesting(false)
    .task {
      guard posedProgress == nil else { return }
      if !reduceMotion {
        withAnimation(.easeOut(duration: Self.fillSeconds)) {
          progress = 1
        }
        try? await Task.sleep(for: Self.fill)
      }
      isFilled = true
      leaveIfReady()
      try? await Task.sleep(for: Self.cap - (reduceMotion ? .zero : Self.fill))
      leave()
    }
    .onChange(of: isReady) { leaveIfReady() }
  }

  private func leaveIfReady() {
    if isFilled && isReady { leave() }
  }

  private func leave() {
    guard posedProgress == nil, !isLeaving else { return }
    withAnimation(.easeOut(duration: Self.exit)) {
      isLeaving = true
    } completion: {
      onFinish()
    }
  }
}
