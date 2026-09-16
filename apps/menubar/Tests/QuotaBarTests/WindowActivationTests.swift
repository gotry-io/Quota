import AppKit
import Foundation
import Testing

@testable import QuotaBar

@Suite(.serialized)
@MainActor
struct WindowActivationTests {
  @Test
  func firstWindowGoesRegularAndLastCloseReturnsAccessory() throws {
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

  @Test
  func registeringTheSameWindowTwiceDoesNotDoubleCount() throws {
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
