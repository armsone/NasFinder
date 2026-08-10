import CryptoKit
import Foundation
import NIO
import NIOSSH

struct SFTPHostKeyTrustRequired: LocalizedError, Sendable {
    let hostKey: String
    let fingerprint: String
    let isChangedKey: Bool

    var errorDescription: String? {
        if isChangedKey {
            return "서버의 SSH 호스트 키가 이전과 다릅니다. 서버 관리자에게 확인하기 전에는 연결하지 마세요."
        }
        return "처음 연결하는 서버입니다. SSH 호스트 키 지문을 확인해 주세요."
    }
}

final class NasFinderSSHHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expectedKey: String?

    init(expectedKey: String?) {
        self.expectedKey = expectedKey
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let serializedKey = String(openSSHPublicKey: hostKey)
        guard serializedKey == expectedKey else {
            validationCompletePromise.fail(
                SFTPHostKeyTrustRequired(
                    hostKey: serializedKey,
                    fingerprint: Self.fingerprint(for: hostKey),
                    isChangedKey: expectedKey != nil
                )
            )
            return
        }
        validationCompletePromise.succeed(())
    }

    private static func fingerprint(for key: NIOSSHPublicKey) -> String {
        var buffer = ByteBuffer()
        key.write(to: &buffer)
        let digest = SHA256.hash(data: Data(buffer.readableBytesView))
        let value = Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(value)"
    }
}
