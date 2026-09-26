import Foundation

/// When this phone may next ask a provider that answered 429.
///
/// The rule is [ADR 0063](../../../docs/decisions/0063-collection-follows-demand-and-activity.md)'s,
/// the same one the Mac keeps: a `Retry-After` above zero is honoured up to an hour; without one
/// the wait starts at five minutes and doubles to thirty. It is kept per provider session — one
/// provider and one account — and it outlives the process, so relaunching the app is not a way
/// round it. A manual refresh may ask a held provider anyway, once a minute.
struct ProviderBackoff: Codable, Equatable, Sendable {
  struct Entry: Codable, Equatable, Sendable {
    /// No read before this instant, unless a manual refresh spends its bypass.
    var until: Date
    /// The wait this entry started, which the next 429 without a `Retry-After` doubles.
    var delaySeconds: Int
    /// When a manual refresh last asked past the wait.
    var bypassedAt: Date?
  }

  static let firstDelaySeconds = 5 * 60
  static let maximumDelaySeconds = 30 * 60
  static let maximumRetryAfterSeconds = 60 * 60
  static let bypassInterval: TimeInterval = 60

  private(set) var entries: [String: Entry] = [:]

  /// Whether a session may be read at `now`. A held session admits a manual read when it has
  /// not had one in the last minute, and that read is the minute's bypass.
  mutating func admits(_ key: String, now: Date, manual: Bool) -> Bool {
    guard var entry = entries[key], now < entry.until else { return true }
    guard manual else { return false }
    if let bypassedAt = entry.bypassedAt,
      now.timeIntervalSince(bypassedAt) < Self.bypassInterval
    {
      return false
    }
    entry.bypassedAt = now
    entries[key] = entry
    return true
  }

  /// The provider answered 429 at `now`.
  mutating func rateLimited(_ key: String, retryAfterSeconds: Int?, now: Date) {
    let previous = entries[key]
    let delay: Int
    if let retryAfterSeconds, retryAfterSeconds > 0 {
      delay = min(retryAfterSeconds, Self.maximumRetryAfterSeconds)
    } else if let previous {
      delay = max(
        Self.firstDelaySeconds, min(previous.delaySeconds * 2, Self.maximumDelaySeconds))
    } else {
      delay = Self.firstDelaySeconds
    }
    entries[key] = Entry(
      until: now.addingTimeInterval(TimeInterval(delay)),
      delaySeconds: delay,
      bypassedAt: previous?.bypassedAt
    )
  }

  /// The provider answered with a reading, so the next 429 starts the schedule again.
  mutating func answered(_ key: String) {
    entries[key] = nil
  }
}

protocol ProviderBackoffStoring: Sendable {
  func load() -> ProviderBackoff
  func save(_ backoff: ProviderBackoff)
}

/// The app's copy, in its own defaults. It holds instants and provider-session keys, never a
/// cookie, so it needs nothing the Keychain gives.
final class UserDefaultsProviderBackoffStore: ProviderBackoffStoring, @unchecked Sendable {
  static let storageKey = "providers.backoff"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> ProviderBackoff {
    guard let data = defaults.data(forKey: Self.storageKey),
      let backoff = try? JSONDecoder().decode(ProviderBackoff.self, from: data)
    else { return ProviderBackoff() }
    return backoff
  }

  func save(_ backoff: ProviderBackoff) {
    if backoff.entries.isEmpty {
      defaults.removeObject(forKey: Self.storageKey)
    } else if let data = try? JSONEncoder().encode(backoff) {
      defaults.set(data, forKey: Self.storageKey)
    }
  }
}

final class MemoryProviderBackoffStore: ProviderBackoffStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var value = ProviderBackoff()

  func load() -> ProviderBackoff {
    lock.withLock { value }
  }

  func save(_ backoff: ProviderBackoff) {
    lock.withLock { value = backoff }
  }
}
