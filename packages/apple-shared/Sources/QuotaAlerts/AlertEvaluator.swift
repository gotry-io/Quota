import Foundation

/// Pure evaluation of local remaining-quota alert rules.
///
/// Input is the rules, the last dedup state, and the current subscription readings. Output is
/// the events to deliver and the state to persist. Sign-out is `AlertDedupState.empty`,
/// not an evaluation.
public enum AlertEvaluator {
  public static func evaluate(
    rules: AlertRules,
    previous: AlertDedupState,
    current: [AlertSubscriptionReading],
    now: Date
  ) -> AlertEvaluation {
    guard rules.enabled else {
      return AlertEvaluation(events: [], state: previous)
    }

    var fired = Set(previous.fired)
    var readings: [ReadingID: AlertStoredReading] = Dictionary(
      uniqueKeysWithValues: previous.readings.map {
        (ReadingID(selector: $0.selector, windowID: $0.windowID), $0)
      }
    )
    var events: [AlertEvent] = []

    for subscription in current {
      guard subscription.status == "available" else { continue }
      for window in Self.evaluatedWindows(in: subscription.windows) {
        let id = ReadingID(selector: subscription.selector, windowID: window.id)
        let previousReading = readings[id]
        let remaining = window.remainingPercent
        let didReset =
          previousReading.map { isWindowReset(previous: $0, current: window, now: now) } ?? false

        if didReset {
          fired = fired.filter { $0.selector != id.selector || $0.windowID != id.windowID }
          if rules.resetReminders {
            let key = AlertDedupKey(
              selector: id.selector,
              windowID: id.windowID,
              resetsAt: window.resetsAt,
              threshold: nil
            )
            if !fired.contains(key) {
              fired.insert(key)
              events.append(
                .windowReset(
                  selector: id.selector, windowID: id.windowID, resetsAt: window.resetsAt)
              )
            }
          }
        }

        for threshold in rules.thresholds(for: subscription.selector) {
          let key = AlertDedupKey(
            selector: id.selector,
            windowID: id.windowID,
            resetsAt: window.resetsAt,
            threshold: threshold
          )
          guard !fired.contains(key) else { continue }
          let shouldFire: Bool
          if let previousReading, !didReset {
            shouldFire =
              previousReading.remainingPercent > Double(threshold)
              && remaining <= Double(threshold)
          } else if previousReading == nil {
            shouldFire = remaining <= Double(threshold)
          } else {
            shouldFire = false
          }
          guard shouldFire else { continue }
          fired.insert(key)
          events.append(
            .thresholdCrossed(
              selector: id.selector,
              windowID: id.windowID,
              threshold: threshold,
              remainingPercent: remaining,
              resetsAt: window.resetsAt
            )
          )
        }

        readings[id] = AlertStoredReading(
          selector: id.selector,
          windowID: id.windowID,
          remainingPercent: remaining,
          resetsAt: window.resetsAt
        )
      }
    }

    return AlertEvaluation(
      events: events,
      state: AlertDedupState(
        fired: Array(fired),
        readings: Array(readings.values)
      ).sorted()
    )
  }

  /// Headline cadence windows, shortest first; otherwise the first percent window.
  public static func evaluatedWindows(
    in windows: [AlertWindowReading]
  ) -> [AlertWindowReading] {
    let order = ["five_hour", "weekly", "monthly"]
    let primary = windows.filter { window in
      window.primaryCadence.map { order.contains($0) } ?? false
    }
    if !primary.isEmpty {
      return primary.sorted { lhs, rhs in
        let left = lhs.primaryCadence.flatMap { order.firstIndex(of: $0) } ?? order.count
        let right = rhs.primaryCadence.flatMap { order.firstIndex(of: $0) } ?? order.count
        return left < right
      }
    }
    return windows.first.map { [$0] } ?? []
  }

  /// Remaining rose, and either the previous `resets_at` has passed or the new one is later.
  private static func isWindowReset(
    previous: AlertStoredReading,
    current: AlertWindowReading,
    now: Date
  ) -> Bool {
    guard current.remainingPercent > previous.remainingPercent else { return false }
    if let previousReset = previous.resetsAt, previousReset <= now {
      return true
    }
    if let previousReset = previous.resetsAt, let nextReset = current.resetsAt,
      nextReset > previousReset
    {
      return true
    }
    return false
  }
}

private struct ReadingID: Hashable {
  var selector: String
  var windowID: String
}
