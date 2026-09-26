import Foundation

// The even-pace tick (`docs/design.md` Even-pace tick): where a window's remaining would stand
// now had it been used at an even rate since it started.
//
// Public API:
// - `EvenPacePosition.remainingPercent(_:now:)` — 0…100, or nil where no tick is drawn.

public enum EvenPacePosition {
  /// Remaining percent at an even burn rate now: `100 × (1 − elapsed share of the window)`.
  ///
  /// A fill ending short of it is burning faster than even. Nil wherever the pace rule does not
  /// answer (``QuotaPace/evaluate(_:now:)`` is `.none`: no reset or cadence, a balance, or too
  /// little of the window elapsed or used), because the tick only accompanies a pace line.
  public static func remainingPercent(_ reading: QuotaPaceReading, now: Date) -> Double? {
    guard QuotaPace.evaluate(reading, now: now) != .none,
      let running = reading.runningWindow(now: now)
    else { return nil }
    return (1 - running.elapsed) * 100
  }
}
