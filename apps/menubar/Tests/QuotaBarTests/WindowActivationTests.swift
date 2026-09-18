import AppKit
import Foundation
import Testing

@testable import QuotaBar

@Suite(.serialized)
@MainActor
struct WindowActivationTests {
  @Test
  func untouchedDefaultsStayAccessoryUntilAWindowRegisters() throws {
    try withDockKeyRemoved {
      _ = NSApplication.shared
      let previous = NSApp.activationPolicy()
      WindowActivation.shared.resetForTests()
      let window = makeOffscreenWindow()
      defer {
        window.close()
        WindowActivation.shared.resetForTests()
        NSApp.setActivationPolicy(previous)
      }

      NSApp.setActivationPolicy(.regular)
      WindowActivation.shared.applyDockVisibility()
      #expect(!DockVisibilityPreference.isShown)
      #expect(NSApp.activationPolicy() == .accessory)

      WindowActivation.shared.register(window)
      #expect(WindowActivation.shared.registeredCount == 1)
      #expect(NSApp.activationPolicy() == .regular)

      window.close()
      #expect(WindowActivation.shared.registeredCount == 0)
      #expect(NSApp.activationPolicy() == .accessory)
    }
  }

  @Test
  func shownPreferenceNeverLeavesRegular() throws {
    try withDockShown(true) {
      _ = NSApplication.shared
      let previous = NSApp.activationPolicy()
      WindowActivation.shared.resetForTests()
      let window = makeOffscreenWindow()
      defer {
        window.close()
        WindowActivation.shared.resetForTests()
        NSApp.setActivationPolicy(previous)
      }

      NSApp.setActivationPolicy(.accessory)
      WindowActivation.shared.applyDockVisibility()
      #expect(NSApp.activationPolicy() == .regular)

      WindowActivation.shared.register(window)
      #expect(WindowActivation.shared.registeredCount == 1)
      #expect(NSApp.activationPolicy() == .regular)

      window.close()
      #expect(WindowActivation.shared.registeredCount == 0)
      #expect(NSApp.activationPolicy() == .regular)
    }
  }

  @Test
  func hiddenPreferenceGoesRegularThenAccessoryOnLastClose() throws {
    try withDockShown(false) {
      _ = NSApplication.shared
      let previous = NSApp.activationPolicy()
      WindowActivation.shared.resetForTests()
      let first = makeOffscreenWindow()
      let second = makeOffscreenWindow()
      defer {
        first.close()
        second.close()
        WindowActivation.shared.resetForTests()
        NSApp.setActivationPolicy(previous)
      }

      WindowActivation.shared.register(first)
      #expect(WindowActivation.shared.registeredCount == 1)
      #expect(NSApp.activationPolicy() == .regular)

      WindowActivation.shared.register(second)
      #expect(WindowActivation.shared.registeredCount == 2)
      #expect(NSApp.activationPolicy() == .regular)

      first.close()
      #expect(WindowActivation.shared.registeredCount == 1)
      #expect(NSApp.activationPolicy() == .regular)

      second.close()
      #expect(WindowActivation.shared.registeredCount == 0)
      #expect(NSApp.activationPolicy() == .accessory)
    }
  }

  @Test
  func registeringTheSameWindowTwiceDoesNotDoubleCount() throws {
    try withDockShown(false) {
      _ = NSApplication.shared
      let previous = NSApp.activationPolicy()
      WindowActivation.shared.resetForTests()
      let window = makeOffscreenWindow()
      defer {
        window.close()
        WindowActivation.shared.resetForTests()
        NSApp.setActivationPolicy(previous)
      }

      WindowActivation.shared.register(window)
      WindowActivation.shared.register(window)
      #expect(WindowActivation.shared.registeredCount == 1)

      window.close()
      #expect(WindowActivation.shared.registeredCount == 0)
      #expect(NSApp.activationPolicy() == .accessory)
    }
  }

  @Test
  func hidingDockWhileAWindowIsRegisteredKeepsRegularAndTheWindow() throws {
    try withDockShown(true) {
      _ = NSApplication.shared
      let previous = NSApp.activationPolicy()
      WindowActivation.shared.resetForTests()
      let window = makeOffscreenWindow()
      defer {
        window.close()
        WindowActivation.shared.resetForTests()
        NSApp.setActivationPolicy(previous)
      }

      WindowActivation.shared.register(window)
      #expect(WindowActivation.shared.registeredCount == 1)
      #expect(NSApp.activationPolicy() == .regular)

      UserDefaults.standard.set(false, forKey: DockVisibilityPreference.storageKey)
      WindowActivation.shared.applyDockVisibility()
      #expect(WindowActivation.shared.registeredCount == 1)
      #expect(NSApp.activationPolicy() == .regular)

      window.close()
      #expect(WindowActivation.shared.registeredCount == 0)
      #expect(NSApp.activationPolicy() == .accessory)
    }
  }
}

@MainActor
private func withDockKeyRemoved(_ body: () throws -> Void) throws {
  let key = DockVisibilityPreference.storageKey
  let previous = UserDefaults.standard.object(forKey: key)
  defer {
    if let previous {
      UserDefaults.standard.set(previous, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
  UserDefaults.standard.removeObject(forKey: key)
  try body()
}

@MainActor
private func withDockShown(_ shown: Bool, _ body: () throws -> Void) throws {
  let key = DockVisibilityPreference.storageKey
  let previous = UserDefaults.standard.object(forKey: key)
  defer {
    if let previous {
      UserDefaults.standard.set(previous, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
  UserDefaults.standard.set(shown, forKey: key)
  try body()
}

@MainActor
private func makeOffscreenWindow() -> NSWindow {
  let window = NSWindow(
    contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 120),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
  )
  window.isReleasedWhenClosed = false
  window.isRestorable = false
  return window
}
