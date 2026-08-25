import Foundation

/// The contract versions this build speaks.
///
/// Each contract carries its own version, because each evolves on its own terms. Sharing a
/// number couples two contracts that have nothing to say to each other: bumping one would
/// force the other to move with it.
public enum QuotaProtocol {
  /// OAuth, Device authorization and control, Account metadata, and the catalogs.
  public static let control = 2
  /// Quota, Usage, and Account summary between a Device and Relay.
  public static let managedData = 4
  /// The private local Usage report the service hands its own app.
  public static let localUsage = 3
  /// The private local quota collection report the service hands its own app.
  public static let localCollection = 2
}
