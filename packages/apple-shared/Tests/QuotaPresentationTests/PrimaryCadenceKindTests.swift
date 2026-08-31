import QuotaPresentation
import Testing

struct PrimaryCadenceKindTests {
  @Test
  func compactTagsAreTheStackedAbbreviations() {
    #expect(PrimaryCadenceKind.fiveHour.compactTag == "5H")
    #expect(PrimaryCadenceKind.weekly.compactTag == "W")
    #expect(PrimaryCadenceKind.monthly.compactTag == "M")
  }

  @Test
  func allCasesIsTheStackedOrder() {
    #expect(PrimaryCadenceKind.allCases.sorted() == PrimaryCadenceKind.allCases)
    #expect(PrimaryCadenceKind.fiveHour < .weekly)
    #expect(PrimaryCadenceKind.weekly < .monthly)
  }
}
