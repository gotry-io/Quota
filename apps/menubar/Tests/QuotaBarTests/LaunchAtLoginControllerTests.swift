import Foundation
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
    #expect(GeneralSettingsCopy.showInDock == "Show in Dock")
    #expect(DockVisibilityPreference.storageKey == "dock.shown")
    #expect(DockVisibilityPreference.fallback)
    #expect(GeneralSettingsCopy.refreshInterval == "Refresh Interval")
    #expect(GeneralSettingsCopy.uploadUsage == "Upload Usage to Account")
    #expect(GeneralSettingsCopy.groupUsage == "Group Usage by project")
    #expect(GeneralSettingsCopy.resetLocalData == "Reset Local Data")
    #expect(ResetLocalDataCopy.title == "Reset Local Data?")
    #expect(ResetLocalDataCopy.confirmTitle == "Reset Local Data")
    #expect(ResetLocalDataCopy.message.contains("deleted and rebuilt"))
    #expect(ResetLocalDataCopy.message.contains("You stay signed in."))
  }

  @Test
  func launchedAsLoginItemReadsTheOpenApplicationPropDataFlag() {
    #expect(!LaunchAtLoginController.launchedAsLoginItem(event: nil))
    #expect(
      !LaunchAtLoginController.launchedAsLoginItem(event: makeOpenApplicationEvent(loginItem: false))
    )
    #expect(
      LaunchAtLoginController.launchedAsLoginItem(event: makeOpenApplicationEvent(loginItem: true))
    )

    let other = NSAppleEventDescriptor(
      eventClass: LaunchAtLoginController.LaunchEvent.coreEventClass,
      eventID: AEEventID(0x6F64_6F63),  // 'odoc'
      targetDescriptor: nil,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    #expect(!LaunchAtLoginController.launchedAsLoginItem(event: other))
  }
}

private func makeOpenApplicationEvent(loginItem: Bool) -> NSAppleEventDescriptor {
  let event = NSAppleEventDescriptor(
    eventClass: LaunchAtLoginController.LaunchEvent.coreEventClass,
    eventID: LaunchAtLoginController.LaunchEvent.openApplication,
    targetDescriptor: nil,
    returnID: AEReturnID(kAutoGenerateReturnID),
    transactionID: AETransactionID(kAnyTransactionID)
  )
  guard loginItem else { return event }
  let propData = NSAppleEventDescriptor.record()
  propData.setDescriptor(
    NSAppleEventDescriptor(boolean: true),
    forKeyword: LaunchAtLoginController.LaunchEvent.launchedAsLoginItem
  )
  event.setParam(propData, forKeyword: LaunchAtLoginController.LaunchEvent.propData)
  return event
}
