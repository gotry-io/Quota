import Foundation

/// The contract versions this build speaks.
///
/// Each contract carries its own version, because each evolves on its own terms. Sharing a
/// number couples two contracts that have nothing to say to each other: bumping one would
/// force the other to move with it.
///
/// The private local reports name no version of their own. They only ever travel nested inside an
/// IPC state that carries `ipc_version`, and both ends of that pipe ship in the same build.
public enum QuotaProtocol {
  /// OAuth, Device authorization and control, Account metadata, and the catalogs.
  public static let control = 2
  /// Quota, Usage, and Account summary between a Device and Relay.
  public static let managedData = 5

  /// No agent this Account accepts existed before this instant, so a coverage window reaching
  /// back past it was computed from a missing lower bound rather than scanned.
  public static let earliestUsageInstant = "2020-01-01T00:00:00Z"
}
