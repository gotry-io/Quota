import Testing

@testable import QuotaBar

struct QuotaStatePresentationTests {
  @Test
  func navigationBufferPublishesImmediatelyWhenThePageIsStable() {
    var buffer = QuotaNavigationPresentationBuffer("loading")

    buffer.receive("content", transitionActive: false)

    #expect(buffer.displayed == "content")
    #expect(buffer.pending == nil)
  }

  @Test
  func navigationBufferCoalescesUpdatesUntilTheTransitionFinishes() {
    var buffer = QuotaNavigationPresentationBuffer("loading")

    buffer.receive("empty", transitionActive: true)
    buffer.receive("content", transitionActive: true)

    #expect(buffer.displayed == "loading")
    #expect(buffer.pending == "content")

    buffer.finishTransition(latest: "content")

    #expect(buffer.displayed == "content")
    #expect(buffer.pending == nil)
  }

  @Test
  func navigationBufferUsesTheLatestValueWhenATransitionEndsWithoutAPendingUpdate() {
    var buffer = QuotaNavigationPresentationBuffer("loading")

    buffer.finishTransition(latest: "error")

    #expect(buffer.displayed == "error")
    #expect(buffer.pending == nil)
  }

  @Test
  func pageStatesProvideSemanticAccessibilityCopy() {
    #expect(
      QuotaPageStatePresentation.loading(title: "Checking diagnostics…").accessibilityLabel
        == "Checking diagnostics…"
    )
    #expect(
      QuotaPageStatePresentation.empty(
        systemImage: "eye.slash",
        title: "No Quota to Show",
        message: "Enable an agent in Settings."
      ).accessibilityLabel
        == "No Quota to Show. Enable an agent in Settings."
    )
    #expect(
      QuotaPageStatePresentation.error(
        title: "Diagnostics Unavailable",
        message: "The service did not respond."
      ).accessibilityLabel
        == "Error: Diagnostics Unavailable. The service did not respond."
    )
  }

  @Test @MainActor
  func inlineNoticesUseShapeAndSpokenSeverityInAdditionToColor() {
    #expect(QuotaNoticeTone.warning.systemImage == "exclamationmark.triangle.fill")
    #expect(QuotaNoticeTone.warning.accessibilityPrefix == "Warning")
    #expect(QuotaNoticeTone.error.systemImage == "exclamationmark.circle.fill")
    #expect(QuotaNoticeTone.error.accessibilityPrefix == "Error")

    let notice = QuotaInlineNotice(message: "Showing saved data.")
    #expect(notice.accessibilityLabel == "Warning: Showing saved data.")
  }

  @Test
  func sectionStatesKeepTheirScopeInAccessibilityCopy() {
    #expect(
      QuotaSectionStatePresentation.loading(title: "Preparing Usage…").accessibilityLabel
        == "Preparing Usage…"
    )
    #expect(
      QuotaSectionStatePresentation.empty(message: "No model usage is available.")
        .accessibilityLabel == "No model usage is available."
    )
    #expect(
      QuotaSectionStatePresentation.error(message: "Models could not be loaded.")
        .accessibilityLabel == "Error: Models could not be loaded."
    )
  }
}
