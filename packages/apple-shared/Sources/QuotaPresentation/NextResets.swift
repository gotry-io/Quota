import Foundation

// Next resets (`docs/design.md` Next resets): the coming seven days, one lane per current
// subscription with a reset in them, one mark per reset instant carrying every window that
// refills at it.
//
// Public API:
// - `ResettingQuotaWindow` — a `RemainingQuotaWindow` that states when it refills.
// - `NextResetInstant<Window>` — one instant, its windows, and the lowest remaining among them.
// - `NextResetsLane<Subscription, Window>` — one subscription's instants, soonest first.
// - `NextResets.lanes(in:isCurrent:windows:now:horizon:)` — the grouping.

/// A window that states when it refills.
public protocol ResettingQuotaWindow: RemainingQuotaWindow {
  var resetsAt: Date? { get }
}

/// One reset instant of one subscription.
public struct NextResetInstant<Window> {
  /// The earliest reset of the windows grouped here.
  public let at: Date
  /// The windows that refill at this instant, in the subscription's window order.
  public let windows: [Window]
  /// The lowest remaining percent among those windows that draw a percent — the band colour of
  /// the mark. Nil when every window here is a balance.
  public let lowestRemainingPercent: Double?

  public init(at: Date, windows: [Window], lowestRemainingPercent: Double?) {
    self.at = at
    self.windows = windows
    self.lowestRemainingPercent = lowestRemainingPercent
  }
}

extension NextResetInstant: Sendable where Window: Sendable {}
extension NextResetInstant: Equatable where Window: Equatable {}

/// One subscription's lane.
public struct NextResetsLane<Subscription, Window> {
  public let subscription: Subscription
  /// Soonest first; never empty.
  public let resets: [NextResetInstant<Window>]

  public init(subscription: Subscription, resets: [NextResetInstant<Window>]) {
    self.subscription = subscription
    self.resets = resets
  }
}

extension NextResetsLane: Sendable where Subscription: Sendable, Window: Sendable {}
extension NextResetsLane: Equatable where Subscription: Equatable, Window: Equatable {}

public enum NextResets {
  /// Seven days, the span the component draws.
  public static let horizon: TimeInterval = 7 * 86_400

  /// The resets after `now` and no later than `now + horizon`, per current subscription, in
  /// `subscriptions` order. Windows share an instant when they reset in the same minute, the
  /// resolution every reset line is printed at. A subscription `isCurrent` refuses, and one
  /// with no reset inside the horizon, has no lane.
  public static func lanes<Subscription, Window: ResettingQuotaWindow>(
    in subscriptions: some Sequence<Subscription>,
    isCurrent: (Subscription) -> Bool,
    windows: (Subscription) -> [Window],
    now: Date,
    horizon: TimeInterval = NextResets.horizon
  ) -> [NextResetsLane<Subscription, Window>] {
    let end = now.addingTimeInterval(horizon)
    var lanes: [NextResetsLane<Subscription, Window>] = []
    for subscription in subscriptions where isCurrent(subscription) {
      var byMinute: [Int: [(at: Date, window: Window)]] = [:]
      for window in windows(subscription) {
        guard let at = window.resetsAt, at > now, at <= end else { continue }
        let minute = Int((at.timeIntervalSince1970 / 60).rounded(.down))
        byMinute[minute, default: []].append((at, window))
      }
      guard !byMinute.isEmpty else { continue }
      let resets = byMinute.keys.sorted().map { minute in
        let group = byMinute[minute] ?? []
        let percents = group.compactMap { entry -> Double? in
          RemainingQuotaFormat.isBalanceOnly(
            remainingValue: entry.window.remainingValue,
            hasLimit: entry.window.limitValue != nil
          ) ? nil : RemainingQuotaFormat.remainingPercent(usedPercent: entry.window.usedPercent)
        }
        return NextResetInstant(
          at: group.map(\.at).min() ?? now,
          windows: group.map(\.window),
          lowestRemainingPercent: percents.min()
        )
      }
      lanes.append(NextResetsLane(subscription: subscription, resets: resets))
    }
    return lanes
  }
}
