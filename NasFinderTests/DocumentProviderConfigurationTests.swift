import XCTest

final class DocumentProviderConfigurationTests: XCTestCase {
    func testLegacyDocumentProviderPairingIsEmbedded() throws {
        let pluginsURL = Bundle.main.bundleURL
            .appendingPathComponent("PlugIns", isDirectory: true)

        let providerInfo = try extensionInfo(
            named: "NasFinderFileProvider",
            in: pluginsURL
        )
        XCTAssertEqual(
            providerInfo["NSExtensionPointIdentifier"] as? String,
            "com.apple.fileprovider-nonui"
        )
        XCTAssertEqual(
            providerInfo["NSExtensionFileProviderDocumentGroup"] as? String,
            "group.com.armsone.nasfinder"
        )
        XCTAssertNil(providerInfo["NSExtensionFileProviderSupportsEnumeration"])

        let pickerInfo = try extensionInfo(
            named: "NasFinderDocumentPicker",
            in: pluginsURL
        )
        XCTAssertEqual(
            pickerInfo["NSExtensionPointIdentifier"] as? String,
            "com.apple.fileprovider-ui"
        )
        let attributes = try XCTUnwrap(
            pickerInfo["NSExtensionAttributes"] as? [String: Any]
        )
        let modes = try XCTUnwrap(attributes["UIDocumentPickerModes"] as? [String])
        XCTAssertEqual(
            Set(modes),
            Set(["UIDocumentPickerModeImport", "UIDocumentPickerModeOpen"])
        )
    }

    private func extensionInfo(
        named name: String,
        in pluginsURL: URL
    ) throws -> [String: Any] {
        let infoURL = pluginsURL
            .appendingPathComponent("\(name).appex", isDirectory: true)
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        return try XCTUnwrap(plist["NSExtension"] as? [String: Any])
    }
}
