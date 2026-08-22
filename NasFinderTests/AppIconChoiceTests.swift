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

    @Test func cyberIconsUseRegisteredAssetNames() {
        #expect(AppIconChoice.allCases.count == 6)
        #expect(AppIconChoice.vibeCoder.alternateIconName == "AppIconVibeCoder")
        #expect(AppIconChoice.cyberVault.alternateIconName == "AppIconCyberVault")
        #expect(AppIconChoice.networkNAS.alternateIconName == "AppIconNetworkNAS")
        #expect(AppIconChoice.enamelNAS.alternateIconName == "AppIconEnamel")
        #expect(AppIconChoice.current(alternateIconName: "AppIconVibeCoder") == .vibeCoder)
        #expect(AppIconChoice.current(alternateIconName: "AppIconCyberVault") == .cyberVault)
        #expect(AppIconChoice.current(alternateIconName: "AppIconNetworkNAS") == .networkNAS)
        #expect(AppIconChoice.current(alternateIconName: "AppIconEnamel") == .enamelNAS)
    }
}
