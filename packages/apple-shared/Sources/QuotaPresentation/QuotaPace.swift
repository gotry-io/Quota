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
  /// Used percent at reset if nothing changes.
  public let projectedAtReset: Double

  public init(tempo: QuotaPaceTempo, deltaPercent: Int, projectedAtReset: Double) {
    self.tempo = tempo
    self.deltaPercent = deltaPercent
    self.projectedAtReset = projectedAtReset
  }
}

/// Whether a window's current burn rate lasts to its reset.
///
/// This module names the answer so a widget snapshot can carry one. It does not derive it;
/// whoever holds the reading produces the value and writes it.
public enum QuotaPace: Equatable, Sendable {
  /// A window this cannot answer for: no cadence, a wallet with no budget to spend against,
  /// or too little of the window behind the reader to mean anything.
  case none
  case lasts(QuotaPaceProjection)
  case runsOut(QuotaPaceProjection, exhaustsAt: Date)

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

/// Wire coding for the `pace` object a publisher may state on a window.
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
