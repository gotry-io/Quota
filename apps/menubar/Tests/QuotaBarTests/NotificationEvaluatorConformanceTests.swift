import Foundation
import Testing

@testable import QuotaBar

/// Quota iOS will answer the same file. A case one of them changes cannot quietly drift.
struct NotificationEvaluatorConformanceTests {
  @Test func everyAlertTransitionCaseMatchesTheSharedFixture() throws {
    let fixture = try AlertTransitionFixture.load()
    #expect(fixture.cases.count >= 8)
    for testCase in fixture.cases {
      if testCase.signOut {
        let store = InMemoryNotificationStateStore(state: testCase.previous ?? .empty)
        try store.clear()
        let loaded = try store.load()
        #expect(eventsMatch([], testCase.expectedEvents), "\(testCase.name)")
        #expect(statesMatch(loaded, testCase.expectedStateAfter), "\(testCase.name)")
        continue
      }
      let result = NotificationEvaluator.evaluate(
        rules: testCase.rules,
        previous: testCase.previous ?? .empty,
        current: testCase.current,
        now: testCase.now
      )
      #expect(eventsMatch(result.events, testCase.expectedEvents), "\(testCase.name)")
      #expect(statesMatch(result.state, testCase.expectedStateAfter), "\(testCase.name)")
    }
  }
}

private func eventsMatch(
  _ actual: [NotificationEvent],
  _ expected: [AlertTransitionFixture.Event]
) -> Bool {
  guard actual.count == expected.count else { return false }
  return zip(actual, expected).allSatisfy { lhs, rhs in
    switch lhs {
    case .thresholdCrossed(let selector, let windowID, let threshold, let remaining, let resetsAt):
      rhs.type == "threshold_crossed"
        && rhs.selector == selector
        && rhs.windowID == windowID
        && rhs.threshold == threshold
        && rhs.remainingPercent == remaining
        && rhs.resetsAt == resetsAt
    case .windowReset(let selector, let windowID, let resetsAt):
      rhs.type == "window_reset"
        && rhs.selector == selector
        && rhs.windowID == windowID
        && rhs.threshold == nil
        && rhs.remainingPercent == nil
        && rhs.resetsAt == resetsAt
    }
  }
}

private func statesMatch(_ actual: NotificationDedupState, _ expected: NotificationDedupState)
  -> Bool
{
  actual.sorted() == expected.sorted()
}

private struct AlertTransitionFixture: Decodable {
  var cases: [Case]

  struct Case {
    var name: String
    var now: Date
    var signOut: Bool
    var rules: NotificationRules
    var previous: NotificationDedupState?
    var current: [NotificationSubscriptionReading]
    var expectedEvents: [Event]
    var expectedStateAfter: NotificationDedupState
  }

  struct Event: Decodable {
    var type: String
    var selector: String
    var windowID: String
    var threshold: Int?
    var remainingPercent: Double?
    var resetsAt: Date?

    enum CodingKeys: String, CodingKey {
      case type
      case selector
      case windowID = "window_id"
      case threshold
      case remainingPercent = "remaining_percent"
      case resetsAt = "resets_at"
    }
  }

  struct RulesDTO: Decodable {
    var enabled: Bool
    var resetReminders: Bool
    var thresholds: [String: [Int]]

    enum CodingKeys: String, CodingKey {
      case enabled
      case resetReminders = "reset_reminders"
      case thresholds
    }
  }

  struct StateDTO: Decodable {
    var fired: [FiredDTO]
    var readings: [ReadingDTO]
  }

  struct FiredDTO: Decodable {
    var selector: String
    var windowID: String
    var resetsAt: Date?
    var threshold: Int?

    enum CodingKeys: String, CodingKey {
      case selector
      case windowID = "window_id"
      case resetsAt = "resets_at"
      case threshold
    }
  }

  struct ReadingDTO: Decodable {
    var selector: String
    var windowID: String
    var remainingPercent: Double
    var resetsAt: Date?

    enum CodingKeys: String, CodingKey {
      case selector
      case windowID = "window_id"
      case remainingPercent = "remaining_percent"
      case resetsAt = "resets_at"
    }
  }

  struct SubscriptionDTO: Decodable {
    var selector: String
    var status: String
    var windows: [WindowDTO]
  }

  struct WindowDTO: Decodable {
    var id: String
    var title: String
    var remainingPercent: Double
    var resetsAt: Date?
    var primaryCadence: String?

    enum CodingKeys: String, CodingKey {
      case id
      case title
      case remainingPercent = "remaining_percent"
      case resetsAt = "resets_at"
      case primaryCadence = "primary_cadence"
    }
  }

  enum CaseKeys: String, CodingKey {
    case name
    case now
    case signOut = "sign_out"
    case rules
    case previous
    case current
    case expectedEvents = "expected_events"
    case expectedStateAfter = "expected_state_after"
  }

  init(from decoder: Decoder) throws {
    let root = try decoder.container(keyedBy: RootKeys.self)
    let rawCases = try root.nestedUnkeyedContainer(forKey: .cases)
    var cursor = rawCases
    var decoded: [Case] = []
    while !cursor.isAtEnd {
      let container = try cursor.nestedContainer(keyedBy: CaseKeys.self)
      let rules = try container.decode(RulesDTO.self, forKey: .rules)
      let previous = try container.decodeIfPresent(StateDTO.self, forKey: .previous)
      let current = try container.decode([SubscriptionDTO].self, forKey: .current)
      let expectedState = try container.decode(StateDTO.self, forKey: .expectedStateAfter)
      decoded.append(
        Case(
          name: try container.decode(String.self, forKey: .name),
          now: try container.decode(Date.self, forKey: .now),
          signOut: try container.decodeIfPresent(Bool.self, forKey: .signOut) ?? false,
          rules: NotificationRules(
            enabled: rules.enabled,
            resetReminders: rules.resetReminders,
            thresholds: rules.thresholds
          ),
          previous: previous.map(Self.state),
          current: current.map { subscription in
            NotificationSubscriptionReading(
              selector: subscription.selector,
              status: subscription.status,
              windows: subscription.windows.map {
                NotificationWindowReading(
                  id: $0.id,
                  title: $0.title,
                  remainingPercent: $0.remainingPercent,
                  resetsAt: $0.resetsAt,
                  primaryCadence: $0.primaryCadence
                )
              }
            )
          },
          expectedEvents: try container.decode([Event].self, forKey: .expectedEvents),
          expectedStateAfter: Self.state(expectedState)
        )
      )
    }
    cases = decoded
  }

  private enum RootKeys: String, CodingKey { case cases }

  private static func state(_ dto: StateDTO) -> NotificationDedupState {
    NotificationDedupState(
      fired: dto.fired.map {
        NotificationDedupKey(
          selector: $0.selector,
          windowID: $0.windowID,
          resetsAt: $0.resetsAt,
          threshold: $0.threshold
        )
      },
      readings: dto.readings.map {
        NotificationStoredReading(
          selector: $0.selector,
          windowID: $0.windowID,
          remainingPercent: $0.remainingPercent,
          resetsAt: $0.resetsAt
        )
      }
    )
  }

  static func load() throws -> AlertTransitionFixture {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(AlertTransitionFixture.self, from: Data(contentsOf: fixtureURL))
  }

  private static let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("packages/protocol/fixtures/alert-transition-conformance.json")
}
