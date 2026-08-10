import ServiceManagement
import Testing

@testable import QuotaBar

@Suite
struct LaunchAtLoginControllerTests {
  @Test
  func enabledIncludesApprovalPending() {
    #expect(LaunchAtLoginController.isEnabled(status: .enabled))
    #expect(LaunchAtLoginController.isEnabled(status: .requiresApproval))
    #expect(!LaunchAtLoginController.isEnabled(status: .notRegistered))
    #expect(!LaunchAtLoginController.isEnabled(status: .notFound))
  }

  @Test
  func recoveryMessageOnlyForBlockedStates() {
    #expect(
      LaunchAtLoginController.message(for: .requiresApproval)?.contains("Login Items") == true)
    #expect(LaunchAtLoginController.message(for: .notFound) != nil)
    #expect(LaunchAtLoginController.message(for: .enabled) == nil)
    #expect(LaunchAtLoginController.message(for: .notRegistered) == nil)
  }
}
