import XCTest
@testable import NasFinder

/// 페어링 페이로드 인코딩·파싱과 핸드셰이크 규칙을 네트워크 없이 검증한다.
final class PhotoTransferPairingTests: XCTestCase {
    /// URL-safe 문자 집합(영숫자, -, _)로 이뤄진 32자 토큰.
    private let validToken = "aB3-_cdEF9ghijkLMN45opqRStuvWX67"

    private func validURLString(
        version: String = "1",
        host: String = "192.168.0.12",
        port: String = "54321",
        token: String? = nil
    ) -> String {
        "nasfinder://photo-transfer/pair?version=\(version)&host=\(host)&port=\(port)&token=\(token ?? validToken)"
    }

    // MARK: - 인코딩·파싱 왕복

    func testPayloadRoundTrip() throws {
        let payload = try XCTUnwrap(
            PhotoTransferPairingPayload(host: "192.168.0.12", port: 54321, token: validToken)
        )
        XCTAssertEqual(
            payload.pairingURLString,
            "nasfinder://photo-transfer/pair?version=1&host=192.168.0.12&port=54321&token=\(validToken)"
        )

        let parsed = try XCTUnwrap(
            PhotoTransferPairingPayload(pairingURLString: payload.pairingURLString)
        )
        XCTAssertEqual(parsed, payload)
        XCTAssertEqual(parsed.version, 1)
        XCTAssertEqual(parsed.host, "192.168.0.12")
        XCTAssertEqual(parsed.port, 54321)
        XCTAssertEqual(parsed.token, validToken)
    }

    func testParsesQueryItemsInAnyOrder() {
        let reordered = "nasfinder://photo-transfer/pair?token=\(validToken)&port=8080&version=1&host=10.0.1.2"
        let parsed = PhotoTransferPairingPayload(pairingURLString: reordered)
        XCTAssertEqual(parsed?.host, "10.0.1.2")
        XCTAssertEqual(parsed?.port, 8080)
        XCTAssertEqual(parsed?.token, validToken)
    }

    func testDirectInitializerRejectsInvalidFields() {
        XCTAssertNil(PhotoTransferPairingPayload(host: "not-an-ip", port: 80, token: validToken))
        XCTAssertNil(PhotoTransferPairingPayload(host: "192.168.0.12", port: 0, token: validToken))
        XCTAssertNil(PhotoTransferPairingPayload(host: "192.168.0.12", port: 80, token: "short"))
    }

    // MARK: - 스킴·호스트·경로 검증

    func testRejectsWrongSchemeHostOrPath() {
        XCTAssertNil(PhotoTransferPairingPayload(pairingURLString: ""))
        XCTAssertNil(PhotoTransferPairingPayload(
            pairingURLString: "https://photo-transfer/pair?version=1&host=192.168.0.12&port=80&token=\(validToken)"
        ))
        XCTAssertNil(PhotoTransferPairingPayload(
            pairingURLString: "nasfinder://other-feature/pair?version=1&host=192.168.0.12&port=80&token=\(validToken)"
        ))
        XCTAssertNil(PhotoTransferPairingPayload(
            pairingURLString: "nasfinder://photo-transfer/other?version=1&host=192.168.0.12&port=80&token=\(validToken)"
        ))
        XCTAssertNil(PhotoTransferPairingPayload(
            pairingURLString: "nasfinder://photo-transfer/pair"
        ))
    }

    // MARK: - 개별 필드 거부

    func testRejectsMalformedVersion() {
        for version in ["0", "2", "01", "1.0", "abc", ""] {
            XCTAssertNil(
                PhotoTransferPairingPayload(pairingURLString: validURLString(version: version)),
                "version=\(version) 은 거부되어야 합니다."
            )
        }
        XCTAssertNil(PhotoTransferPairingPayload(
            pairingURLString: "nasfinder://photo-transfer/pair?host=192.168.0.12&port=80&token=\(validToken)"
        ), "version 누락은 거부되어야 합니다.")
    }

    func testRejectsMalformedHost() {
        for host in [
            "256.1.1.1", "1.2.3", "1.2.3.4.5", "01.2.3.4", "1.2.3.04",
            "0.0.0.0", "255.255.255.255", "abc", "1.2.3.a", "", "1..2.3",
        ] {
            XCTAssertNil(
                PhotoTransferPairingPayload(pairingURLString: validURLString(host: host)),
                "host=\(host) 은 거부되어야 합니다."
            )
        }
    }

    func testRejectsMalformedPort() {
        for port in ["0", "65536", "-1", "abc", "080", "", "8080.5"] {
            XCTAssertNil(
                PhotoTransferPairingPayload(pairingURLString: validURLString(port: port)),
                "port=\(port) 은 거부되어야 합니다."
            )
        }
        XCTAssertNotNil(PhotoTransferPairingPayload(pairingURLString: validURLString(port: "1")))
        XCTAssertNotNil(PhotoTransferPairingPayload(pairingURLString: validURLString(port: "65535")))
    }

    func testRejectsMalformedToken() {
        let tooLong = String(repeating: "a", count: 129)
        for token in ["", "short", "abc/def-with-enough-length", "has space padding-x", tooLong] {
            XCTAssertNil(
                PhotoTransferPairingPayload(pairingURLString: validURLString(token: token)),
                "token=\(token.prefix(20)) 은 거부되어야 합니다."
            )
        }
        // 퍼센트 인코딩을 풀었을 때 허용되지 않는 문자가 나오면 거부.
        XCTAssertNil(PhotoTransferPairingPayload(
            pairingURLString: validURLString(token: "abc%2Fdef-with-enough-length")
        ))
    }

    func testRejectsDuplicateOrUnknownQueryItems() {
        XCTAssertNil(PhotoTransferPairingPayload(
            pairingURLString: validURLString() + "&extra=1"
        ), "알 수 없는 쿼리 키는 거부되어야 합니다.")
        XCTAssertNil(PhotoTransferPairingPayload(
            pairingURLString: validURLString() + "&token=\(validToken)"
        ), "중복 쿼리 키는 거부되어야 합니다.")
    }

    // MARK: - 토큰 생성

    func testGeneratedTokenIsURLSafeAndUnique() {
        let first = PhotoTransferPairingPayload.makeToken()
        let second = PhotoTransferPairingPayload.makeToken()
        XCTAssertTrue(PhotoTransferPairingPayload.isValidToken(first))
        XCTAssertTrue(PhotoTransferPairingPayload.isValidToken(second))
        XCTAssertNotEqual(first, second)
        // 32바이트 → 패딩 없는 base64url 43자
        XCTAssertEqual(first.count, 43)
    }

    // MARK: - 핸드셰이크

    func testHandshakeClientLineFormat() {
        XCTAssertEqual(
            PhotoTransferHandshake.clientLine(token: validToken),
            "NASFINDER_PHOTO/3 \(validToken) ios grouped-v1\n"
        )
    }

    func testHandshakeAcceptsMatchingToken() {
        XCTAssertEqual(
            PhotoTransferHandshake.response(
                toClientLine: "NASFINDER_PHOTO/3 \(validToken) android grouped-v1",
                expectedToken: validToken
            ),
            "OK ios grouped-v1\n"
        )
        let decision = PhotoTransferHandshake.decision(
            toClientLine: "NASFINDER_PHOTO/3 \(validToken) android grouped-v1",
            expectedToken: validToken
        )
        XCTAssertEqual(decision.peerPlatform, .android)
        XCTAssertTrue(decision.accepted)
        XCTAssertTrue(decision.supportsGroupedTransfer)
        XCTAssertEqual(PhotoTransferHandshake.acceptedPeerPlatform(fromResponse: "OK android grouped-v1\n"), .android)
        XCTAssertTrue(PhotoTransferHandshake.acceptedPeer(fromResponse: "OK android grouped-v1\n")?.supportsGroupedTransfer == true)
    }

    func testHandshakeKeepsVersionOneCompatibility() {
        let decision = PhotoTransferHandshake.decision(
            toClientLine: "NASFINDER_PHOTO/1 \(validToken)",
            expectedToken: validToken
        )
        XCTAssertEqual(decision.response, "OK\n")
        XCTAssertEqual(decision.peerPlatform, .unknown)
        XCTAssertFalse(decision.supportsGroupedTransfer)
        XCTAssertEqual(PhotoTransferHandshake.acceptedPeerPlatform(fromResponse: "OK\n"), .unknown)
    }

    func testHandshakeKeepsVersionTwoFlatCompatibility() {
        let decision = PhotoTransferHandshake.decision(
            toClientLine: "NASFINDER_PHOTO/2 \(validToken) android",
            expectedToken: validToken
        )
        XCTAssertEqual(decision.response, "OK ios\n")
        XCTAssertEqual(decision.peerPlatform, .android)
        XCTAssertFalse(decision.supportsGroupedTransfer)
    }

    func testHandshakeRejectsWrongOrMalformedLines() {
        let cases = [
            "NASFINDER_PHOTO/1 wrong-token-value-1234567890",
            "NASFINDER_PHOTO/2 \(validToken)",
            "NASFINDER_PHOTO/2 \(validToken) windows",
            "NASFINDER_PHOTO/3 \(validToken) android",
            "NASFINDER_PHOTO/3 \(validToken) android unknown-capability",
            "OTHER_PROTOCOL/1 \(validToken)",
            "NASFINDER_PHOTO/1",
            "NASFINDER_PHOTO/1 \(validToken) extra",
            "NASFINDER_PHOTO/1  \(validToken)",
            "",
        ]
        for line in cases {
            XCTAssertEqual(
                PhotoTransferHandshake.response(toClientLine: line, expectedToken: validToken),
                "ERROR\n",
                "'\(line)' 은 거부되어야 합니다."
            )
        }
        // 토큰이 이미 소모된(빈) 상태에서는 항상 거부.
        XCTAssertEqual(
            PhotoTransferHandshake.response(
                toClientLine: "NASFINDER_PHOTO/2 \(validToken) ios",
                expectedToken: ""
            ),
            "ERROR\n"
        )
    }

    func testPipelineRouteDistinguishesSameAndCrossPlatform() {
        XCTAssertEqual(
            PhotoTransferMediaPipelineRoute.route(source: .ios, destination: .ios),
            .preserveOriginal
        )
        XCTAssertEqual(
            PhotoTransferMediaPipelineRoute.route(source: .ios, destination: .android),
            .crossPlatformConversion(source: .ios, destination: .android)
        )
        XCTAssertEqual(
            PhotoTransferMediaPipelineRoute.route(source: .ios, destination: .unknown),
            .compatibility
        )
    }

    func testSenderTimeoutRejectsStaleGenerationAndConnection() {
        XCTAssertTrue(
            PhotoTransferSenderSession.isCurrentAttempt(
                callbackGeneration: 4,
                currentGeneration: 4,
                connectionMatches: true
            )
        )
        XCTAssertFalse(
            PhotoTransferSenderSession.isCurrentAttempt(
                callbackGeneration: 3,
                currentGeneration: 4,
                connectionMatches: true
            )
        )
        XCTAssertFalse(
            PhotoTransferSenderSession.isCurrentAttempt(
                callbackGeneration: 4,
                currentGeneration: 4,
                connectionMatches: false
            )
        )
    }

    func testSenderTimeoutMessageDistinguishesStagesAndIncludesLastError() {
        XCTAssertEqual(
            PhotoTransferSenderSession.timeoutDuration(for: .tcpConnection),
            .seconds(10)
        )
        XCTAssertEqual(
            PhotoTransferSenderSession.timeoutDuration(for: .handshakeResponse),
            .seconds(10)
        )
        XCTAssertEqual(
            PhotoTransferSenderSession.timeoutMessage(
                for: .tcpConnection,
                lastErrorDescription: nil
            ),
            "받는 기기에 연결하는 시간이 초과되었습니다."
        )
        XCTAssertEqual(
            PhotoTransferSenderSession.timeoutMessage(
                for: .handshakeResponse,
                lastErrorDescription: "네트워크에 연결할 수 없음"
            ),
            "받는 기기의 연결 응답 시간이 초과되었습니다. 마지막 네트워크 오류: 네트워크에 연결할 수 없음"
        )
    }

    func testManualConnectionCodeContainsTheOneTimeToken() throws {
        let payload = try XCTUnwrap(
            PhotoTransferPairingPayload(host: "192.168.0.12", port: 54_321, token: validToken)
        )
        XCTAssertTrue(payload.pairingURLString.contains("token=\(validToken)"))
        XCTAssertEqual(
            PhotoTransferPairingPayload(pairingURLString: payload.pairingURLString),
            payload
        )
    }

    func testDismissalPolicyOnlyConfirmsActiveWork() throws {
        let payload = try XCTUnwrap(
            PhotoTransferPairingPayload(host: "192.168.0.12", port: 54_321, token: validToken)
        )
        XCTAssertFalse(
            PhotoTransferDismissalPolicy.receiverRequiresConfirmation(
                phase: .waitingForSender(payload),
                transferFinished: false
            )
        )
        XCTAssertTrue(
            PhotoTransferDismissalPolicy.receiverRequiresConfirmation(
                phase: .senderConnected(payload, .android),
                transferFinished: false
            )
        )
        XCTAssertFalse(
            PhotoTransferDismissalPolicy.receiverRequiresConfirmation(
                phase: .senderConnected(payload, .android),
                transferFinished: true
            )
        )
        XCTAssertTrue(
            PhotoTransferDismissalPolicy.senderRequiresConfirmation(
                phase: .connecting(payload),
                isSending: false,
                transferFinished: false
            )
        )
        XCTAssertTrue(
            PhotoTransferDismissalPolicy.senderRequiresConfirmation(
                phase: .connected(payload, .android),
                isSending: true,
                transferFinished: false
            )
        )
        XCTAssertFalse(
            PhotoTransferDismissalPolicy.senderRequiresConfirmation(
                phase: .connected(payload, .android),
                isSending: false,
                transferFinished: false
            )
        )
    }

    func testTransferOperationsUseBoundedTimeout() {
        XCTAssertEqual(PhotoTransferSenderSession.operationTimeoutDuration, .seconds(120))
        XCTAssertEqual(
            PhotoTransferSenderSession.OperationTimeoutError.frameSend.errorDescription,
            "파일 데이터 전송 시간이 초과되었습니다."
        )
        XCTAssertEqual(
            PhotoTransferSenderSession.OperationTimeoutError.resultAcknowledgement.errorDescription,
            "받는 기기의 저장 확인 응답 시간이 초과되었습니다."
        )
    }
}
