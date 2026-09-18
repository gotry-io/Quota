import QuotaWire
import Testing

struct BillingAgentTests {
  @Test
  func everyCaseHasANonEmptyDisplayNameAndClaudeCodeIsClaudeCode() {
    for agent in BillingAgent.allCases {
      #expect(!agent.displayName.isEmpty)
    }
    #expect(BillingAgent.claudeCode.displayName == "Claude Code")
  }
}
