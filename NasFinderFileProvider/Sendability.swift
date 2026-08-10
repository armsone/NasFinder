import Foundation

/// FileProvider's Objective-C observer and callback protocols do not yet carry
/// Sendable annotations. The system owns their lifetime and supports async use.
final class ProviderSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
