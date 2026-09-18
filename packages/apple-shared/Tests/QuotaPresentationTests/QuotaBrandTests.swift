import QuotaPresentation
import Testing

struct QuotaBrandTests {
  @Test
  func componentsRoundToDocumentedHex() {
    #expect(Int((QuotaBrand.emerald.red * 255).rounded()) == 0x08)
    #expect(Int((QuotaBrand.emerald.green * 255).rounded()) == 0x74)
    #expect(Int((QuotaBrand.emerald.blue * 255).rounded()) == 0x56)
    #expect(Int((QuotaBrand.mint.red * 255).rounded()) == 0x82)
    #expect(Int((QuotaBrand.mint.green * 255).rounded()) == 0xDD)
    #expect(Int((QuotaBrand.mint.blue * 255).rounded()) == 0xB8)
  }
}
