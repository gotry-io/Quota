import AppKit
import Foundation
import Testing

@testable import QuotaBar

struct QuitDecisionTests {
  @Test
  func onlyAPlainQuitWithTheWindowOpenClosesTheWindowInsteadOfQuitting() {
    #expect(
      QuitDecision.resolve(
        windowPresented: true, fullQuitRequested: false, systemQuit: false
      ) == .closeWindow)
    #expect(
      QuitDecision.resolve(
        windowPresented: true, fullQuitRequested: true, systemQuit: false
      ) == .terminate)
    #expect(
      QuitDecision.resolve(
        windowPresented: true, fullQuitRequested: false, systemQuit: true
      ) == .terminate)
    #expect(
      QuitDecision.resolve(
        windowPresented: false, fullQuitRequested: false, systemQuit: false
      ) == .terminate)
    #expect(
      QuitDecision.resolve(
        windowPresented: false, fullQuitRequested: true, systemQuit: true
      ) == .terminate)
  }

  @Test
  func quitReasonParamMarksASystemQuit() {
    #expect(!QuitIntent.isSystemQuit(event: nil))
    #expect(!QuitIntent.isSystemQuit(event: makeQuitEvent(reason: false)))
    #expect(QuitIntent.isSystemQuit(event: makeQuitEvent(reason: true)))

    let other = NSAppleEventDescriptor(
      eventClass: QuitIntent.Event.coreEventClass,
      eventID: AEEventID(0x6F61_7070),  // 'oapp'
      targetDescriptor: nil,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    #expect(!QuitIntent.isSystemQuit(event: other))
  }
}

@MainActor
struct QuitKeepRunningExplanationTests {
  @Test
  func firstCloseWindowExplanationIsOfferedOnce() {
    let key = QuitKeepRunningExplanation.storageKey
    let previous = UserDefaults.standard.object(forKey: key)
    let previousPresenter = QuitKeepRunningExplanation.present
    defer {
      if let previous {
        UserDefaults.standard.set(previous, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
      QuitKeepRunningExplanation.present = previousPresenter
    }
    UserDefaults.standard.removeObject(forKey: key)

    var recorded: [QuitKeepRunningExplanation.Choice] = []
    QuitKeepRunningExplanation.present = {
      recorded.append(.acknowledged)
      return .acknowledged
    }

    QuitKeepRunningExplanation.presentIfNeeded()
    QuitKeepRunningExplanation.presentIfNeeded()
    #expect(recorded == [.acknowledged])
    #expect(UserDefaults.standard.bool(forKey: key))
  }
}

private func makeQuitEvent(reason: Bool) -> NSAppleEventDescriptor {
  let event = NSAppleEventDescriptor(
    eventClass: QuitIntent.Event.coreEventClass,
    eventID: QuitIntent.Event.quitApplication,
    targetDescriptor: nil,
    returnID: AEReturnID(kAutoGenerateReturnID),
    transactionID: AETransactionID(kAnyTransactionID)
  )
  guard reason else { return event }
  event.setParam(
    NSAppleEventDescriptor(enumCode: AEEventID(0x6C6F_676F)),  // 'logo' — any value
    forKeyword: QuitIntent.Event.quitReason
  )
  return event
}
