import Foundation

/// How far off an even burn rate a window is running.
public enum QuotaPaceTempo: String, Codable, Equatable, Sendable {
  case ahead
  case onTrack = "on_track"
  case behind
}

/// Where the current rate lands this window by the time it resets.
public struct QuotaPaceProjection: Equatable, Sendable {
  public let tempo: QuotaPaceTempo
  /// The projection stated as a difference from the even rate: `+42` or `-30`.
  public let deltaPercent: Int
  /// Used percent at reset if nothing changes, capped at ``QuotaPace/maximumProjectionPercent``.
  public let projectedAtReset: Double

  public init(tempo: QuotaPaceTempo, deltaPercent: Int, projectedAtReset: Double) {
    self.tempo = tempo
    self.deltaPercent = deltaPercent
    self.projectedAtReset = projectedAtReset
  }
}

/// Whether a window's current burn rate lasts to its reset, derived from the reading alone.
///
/// `usedPercent`, `resetsAt`, and the window cadence are the whole input, so whoever holds a
/// reading answers it without history and without a collector having projected anything.
/// Quota iOS derives it here because there is no Rust on iOS; QuotaBar is handed the answer
/// its service already derived. See ADR 0035.
public enum QuotaPace: Equatable, Sendable {
  /// A window this cannot answer for: no cadence, a wallet with no budget to spend against,
  /// or too little of the window behind the reader to mean anything.
  case none
  case lasts(QuotaPaceProjection)
  case runsOut(QuotaPaceProjection, exhaustsAt: Date)

  /// Below this much of the window elapsed, the sample says nothing about the rest of it.
  public static let minimumElapsedFraction = 0.05

  /// Below this much used, the sample says nothing either: a few percent is noise, not a rate.
  public static let minimumUsedPercent = 2.0

  /// The projection is a ratio of a small number and runs away; this is where it stops.
  public static let maximumProjectionPercent = 999.0

  /// Inside this band of the even rate, a window is neither ahead nor behind.
  public static let onTrackBand = 0.9...1.1

  public var projection: QuotaPaceProjection? {
    switch self {
    case .none: nil
    case .lasts(let projection): projection
    case .runsOut(let projection, _): projection
    }
  }

  public var isRunsOut: Bool {
    if case .runsOut = self { return true }
    return false
  }

  /// The pace of one window.
  public static func evaluate(_ reading: QuotaPaceReading, now: Date) -> QuotaPace {
    guard let resetsAt = reading.resetsAt, let seconds = reading.cadenceSeconds,
      seconds > 0, !reading.isBalanceOnly
    else {
      return .none
    }
    let cadence = Double(seconds)
    let windowStart = resetsAt.addingTimeInterval(-cadence)
    let elapsed = min(max(now.timeIntervalSince(windowStart) / cadence, 0), 1)
    let used = reading.usedPercent
    guard elapsed >= minimumElapsedFraction, used >= minimumUsedPercent else { return .none }
    let projected = min(used / elapsed, maximumProjectionPercent)
    let ratio = projected / 100
    let tempo: QuotaPaceTempo =
      ratio > onTrackBand.upperBound
      ? .ahead : ratio < onTrackBand.lowerBound ? .behind : .onTrack
    let projection = QuotaPaceProjection(
      tempo: tempo,
      deltaPercent: Int(((ratio - 1) * 100).rounded()),
      projectedAtReset: projected
    )
    guard projected > 100 else { return .lasts(projection) }
    // At the current rate the window is spent this far into itself, stated to the second so
    // every runtime names the same instant.
    let offset = (cadence * (100 / used) * elapsed).rounded()
    return .runsOut(projection, exhaustsAt: windowStart.addingTimeInterval(offset))
  }
}

/// A window as pace reads it.
public struct QuotaPaceReading: Equatable, Sendable {
  public let usedPercent: Double
  public let resetsAt: Date?
  public let cadenceSeconds: Int?
  public let isBalanceOnly: Bool

  public init(usedPercent: Double, resetsAt: Date?, cadenceSeconds: Int?, isBalanceOnly: Bool) {
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
    self.cadenceSeconds = cadenceSeconds
    self.isBalanceOnly = isBalanceOnly
  }
}

/// Wire coding for the `pace` object QuotaBar's service states on every IPC window.
///
/// The keys are camelCase because every decoder that reads this type converts the wire's
/// `snake_case` before looking one up, the way the rest of the Apple wire types are read.
extension QuotaPace: Codable {
  private enum Kind: String, Codable {
    case none
    case lasts
    case runsOut = "runs_out"
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case tempo
    case deltaPercent
    case projectedAtReset
    case exhaustsAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    guard kind != .none else {
      self = .none
      return
    }
    let projection = QuotaPaceProjection(
      tempo: try container.decode(QuotaPaceTempo.self, forKey: .tempo),
      deltaPercent: try container.decode(Int.self, forKey: .deltaPercent),
      projectedAtReset: try container.decode(Double.self, forKey: .projectedAtReset)
    )
    self =
      kind == .lasts
      ? .lasts(projection)
      : .runsOut(projection, exhaustsAt: try container.decode(Date.self, forKey: .exhaustsAt))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .none:
      try container.encode(Kind.none, forKey: .kind)
    case .lasts(let projection):
      try container.encode(Kind.lasts, forKey: .kind)
      try encode(projection, into: &container)
    case .runsOut(let projection, let exhaustsAt):
      try container.encode(Kind.runsOut, forKey: .kind)
      try encode(projection, into: &container)
      try container.encode(exhaustsAt, forKey: .exhaustsAt)
    }
  }

  private func encode(
    _ projection: QuotaPaceProjection,
    into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    try container.encode(projection.tempo, forKey: .tempo)
    try container.encode(projection.deltaPercent, forKey: .deltaPercent)
    try container.encode(projection.projectedAtReset, forKey: .projectedAtReset)
  }
}

/// The one line every Quota surface prints for a pace.
///
/// The phrases live in `apps/menubar/DESIGN.md` Shared product vocabulary, and
/// `packages/protocol/fixtures/quota-pace-conformance.json` is the shared statement of them;
/// `apps/web/src/lib/format.ts` answers the same file.
public enum QuotaPaceCopy: Sendable {
  /// `On track · lasts to reset`, `Ahead +42% · runs out ~2h before reset`, or `nil` when
  /// there is no pace to state.
  public static func line(_ pace: QuotaPace, resetsAt: Date?) -> String? {
    guard let projection = pace.projection else { return nil }
    let outcome: String
    switch pace {
    case .none:
      return nil
    case .lasts:
      outcome = "lasts to reset"
    case .runsOut(_, let exhaustsAt):
      guard let resetsAt else { return nil }
      let ahead = CompactAgeFormat.string(since: exhaustsAt, now: resetsAt)
      outcome = "runs out ~\(ahead) before reset"
    }
    return "\(tempo(projection)) · \(outcome)"
  }

  private static func tempo(_ projection: QuotaPaceProjection) -> String {
    switch projection.tempo {
    case .onTrack: "On track"
    case .ahead: "Ahead +\(projection.deltaPercent)%"
    case .behind: "Behind −\(abs(projection.deltaPercent))%"
    }
  }
}
