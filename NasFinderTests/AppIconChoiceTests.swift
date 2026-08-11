import Testing
@testable import NasFinder

struct AppIconChoiceTests {
    @Test func defaultIconUsesPrimaryAppIcon() {
        #expect(AppIconChoice.blueNAS.alternateIconName == nil)
        #expect(AppIconChoice.current(alternateIconName: nil) == .blueNAS)
    }

    @Test func alternateIconUsesRegisteredAssetName() {
        #expect(AppIconChoice.purpleNAS.alternateIconName == "AppIconAlternate")
        #expect(AppIconChoice.current(alternateIconName: "AppIconAlternate") == .purpleNAS)
    }

    @Test func unknownIconFallsBackToDefault() {
        #expect(AppIconChoice.current(alternateIconName: "Unknown") == .blueNAS)
    }
}
