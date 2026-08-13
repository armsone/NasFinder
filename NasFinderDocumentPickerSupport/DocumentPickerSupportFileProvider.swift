import FileProvider

@available(iOS, deprecated: 11.0, message: "Compatibility provider for the legacy document picker UI")
final class NasFinderDocumentPickerSupportFileProvider: NSFileProviderExtension {
    override func providePlaceholder(
        at url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(CocoaError(.fileNoSuchFile))
    }

    override func startProvidingItem(
        at url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        completionHandler(nil)
    }

    override func stopProvidingItem(at url: URL) {
        // Files owns the lifetime of the downloaded working copy. Keeping it in
        // the provider storage avoids deleting a file while a host still uses it.
    }

    override func itemChanged(at url: URL) {
        // The picker returns a local working copy. It never writes host edits
        // back to the NAS without an explicit upload operation in NasFinder.
    }
}
