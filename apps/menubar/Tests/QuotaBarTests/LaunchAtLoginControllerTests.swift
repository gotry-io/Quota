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

  @Test
  func generalPageKeepsLaunchAtLoginWithTheOtherWindowControls() {
    #expect(GeneralSettingsCopy.launchAtLogin == "Launch at Login")
    #expect(GeneralSettingsCopy.refreshInterval == "Refresh Interval")
    #expect(GeneralSettingsCopy.uploadUsage == "Upload Usage to Account")
    #expect(GeneralSettingsCopy.groupUsage == "Group Usage by project")
    #expect(GeneralSettingsCopy.resetLocalData == "Reset Local Data")
    #expect(ResetLocalDataCopy.title == "Reset Local Data?")
    #expect(ResetLocalDataCopy.confirmTitle == "Reset Local Data")
    #expect(ResetLocalDataCopy.message.contains("deleted and rebuilt"))
    #expect(ResetLocalDataCopy.message.contains("You stay signed in."))
  }
}
