import Foundation

// Which colour every chart, ledger swatch, and flow on a surface gives a model (ADR 0064 §2,
// `docs/design.md` Model colours). One assignment per surface, made from the Account's `all`
// period, so switching period, page, or device never recolours a model.
//
// Public API:
// - `ModelSwatch` — `.shade(family, 1…4)` or `.other`, and the token colour it names.
// - `ModelColorAssignment` — built once from the `all` leaves; answers `swatch(for:)`.

/// A model's fill: its provider's family at a shade, or the shared neutral `other`.
public enum ModelSwatch: Hashable, Sendable {
  /// `shade` is 1…``ModelColorAssignment/shadesPerFamily``; 1 stands out most.
  case shade(ModelFamily, Int)
  case other

  /// The token colour (`color.model.<family>.<shade>` or `color.model.other`).
  public var color: DesignTokens.AdaptiveRGB {
    switch self {
    case .shade(let family, let shade): DesignTokens.Color.model(family, shade: shade)
    case .other: DesignTokens.Color.modelOther
    }
  }
}

/// The one model-colour assignment a surface makes.
///
/// The family is the model's inference provider. The shade is the model's rank, 1-based, by total
/// tokens inside that provider over the Account's `all` period, merged across agents; ties go to
/// the model name in ascending order so every device agrees. Rank 5 and below, a model `all` never
/// saw, and the folded `other` series of a top-N chart are all ``ModelSwatch/other``. Colour is
/// never assigned by rank across providers.
public struct ModelColorAssignment: Equatable, Sendable {
  public static let shadesPerFamily = 4

  private let shades: [ModelKey: Int]

  /// An assignment in which every model is `other` — before the `all` period has loaded.
  public static let empty = ModelColorAssignment(tokensByModel: [:])

  /// Ranks the `all` period's leaves, merging a model's tokens across agents first.
  public init<Agent>(all leaves: [ModelUsageLeaf<Agent>]) {
    var tokens: [ModelKey: Int] = [:]
    for leaf in leaves {
      tokens[leaf.key, default: 0] += leaf.totals.totalTokens
    }
    self.init(tokensByModel: tokens)
  }

  /// Ranks models already summed over the `all` period. A model with no tokens takes no shade.
  public init(tokensByModel: [ModelKey: Int]) {
    var byFamily: [ModelFamily: [(model: String, tokens: Int)]] = [:]
    for (key, tokens) in tokensByModel where tokens > 0 {
      byFamily[key.family, default: []].append((key.model, tokens))
    }
    var shades: [ModelKey: Int] = [:]
    for (family, models) in byFamily {
      let ranked = models.sorted {
        $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.model < $1.model
      }
      for (index, entry) in ranked.prefix(Self.shadesPerFamily).enumerated() {
        shades[ModelKey(family: family, model: entry.model)] = index + 1
      }
    }
    self.shades = shades
  }

  public func swatch(for key: ModelKey) -> ModelSwatch {
    shades[key].map { .shade(key.family, $0) } ?? .other
  }

  /// A series entry's swatch: `family` is nil only for the folded `other` series.
  public func swatch(family: ModelFamily?, model: String) -> ModelSwatch {
    guard let family else { return .other }
    return swatch(for: ModelKey(family: family, model: model))
  }
}
