import CryptoKit
import XCTest
@testable import NasFinder

/// receipt-v1(v4) 와이어, 수신 저널, 발신 계획, 삭제 자격 판정. 실제 사진 보관함이나 네트워크는 쓰지 않는다.
final class PhotoTransferReceiptTests: XCTestCase {
    private let token = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"
    private let transferId = "0123456789abcdef0123456789abcdef"
    private let receiverId = "receiver_0123456789abcdef"
    private let sha = String(repeating: "ab", count: 32)

    // MARK: 핸드셰이크(토큰 미노출 challenge/proof)

    func testV4HelloChallengeProofRoundTripNeverCarriesTheToken() throws {
        let nonceS = PhotoTransferV4Handshake.makeNonce()
        let nonceR = PhotoTransferV4Handshake.makeNonce()
        XCTAssertTrue(PhotoTransferReceiptWire.isValidNonce(nonceS))
        XCTAssertNotEqual(nonceS, nonceR)

        let hello = PhotoTransferV4Handshake.helloLine(platform: .ios, nonceS: nonceS)
        XCTAssertEqual(hello, "NASFINDER_PHOTO/4 hello ios grouped-v1 receipt-v1 \(nonceS)\n")
        XCTAssertFalse(hello.contains(token), "v4 hello는 토큰을 싣지 않습니다.")
        XCTAssertTrue(PhotoTransferV4Handshake.isHelloPrefix(hello))
        let parsed = try XCTUnwrap(PhotoTransferV4Handshake.parseHello(String(hello.dropLast())))
        XCTAssertEqual(parsed.platform, .ios)
        XCTAssertEqual(parsed.nonceS, nonceS)

        let key = PhotoTransferV4Handshake.handshakeKey(token: token)
        let proofS = PhotoTransferV4Handshake.senderProof(key: key, platformS: .ios, nonceS: nonceS, nonceR: nonceR)
        XCTAssertTrue(PhotoTransferCrypto.isLowercaseHex64(proofS))
        XCTAssertTrue(PhotoTransferV4Handshake.verifySenderProof(proofS, key: key, platformS: .ios, nonceS: nonceS, nonceR: nonceR))
        // 토큰·플랫폼·nonce 중 하나라도 다르면 실패하고, 수신 증명을 발신 증명 자리에 쓸 수 없다(방향 구분).
        let wrongKey = PhotoTransferV4Handshake.handshakeKey(token: token + "x")
        XCTAssertFalse(PhotoTransferV4Handshake.verifySenderProof(proofS, key: wrongKey, platformS: .ios, nonceS: nonceS, nonceR: nonceR))
        XCTAssertFalse(PhotoTransferV4Handshake.verifySenderProof(proofS, key: key, platformS: .android, nonceS: nonceS, nonceR: nonceR))
        XCTAssertFalse(PhotoTransferV4Handshake.verifySenderProof(proofS, key: key, platformS: .ios, nonceS: nonceR, nonceR: nonceS))
        let proofR = PhotoTransferV4Handshake.receiverProof(key: key, platformR: .ios, nonceS: nonceS, nonceR: nonceR)
        XCTAssertNotEqual(proofS, proofR)
        XCTAssertFalse(PhotoTransferV4Handshake.verifySenderProof(proofR, key: key, platformS: .ios, nonceS: nonceS, nonceR: nonceR))
        XCTAssertTrue(PhotoTransferV4Handshake.verifyReceiverProof(proofR, key: key, platformR: .ios, nonceS: nonceS, nonceR: nonceR))

        let ok = try XCTUnwrap(PhotoTransferV4Handshake.parseOK(String(PhotoTransferV4Handshake.okLine(platform: .android, proof: proofR).dropLast())))
        XCTAssertEqual(ok.platform, .android)
        XCTAssertEqual(ok.proof, proofR)
        XCTAssertEqual(PhotoTransferV4Handshake.parseChallenge("CHALLENGE \(nonceR)"), nonceR)
        XCTAssertEqual(PhotoTransferV4Handshake.parseProof("PROOF \(proofS)"), proofS)
    }

    func testV4SessionKeyDependsOnBothNoncesAndTheToken() {
        let key = PhotoTransferV4Handshake.handshakeKey(token: token)
        let a = PhotoTransferV4Handshake.sessionKey(key: key, nonceS: "AAAAAAAAAAAAAAAAAAAAAA", nonceR: "BBBBBBBBBBBBBBBBBBBBBB")
        let b = PhotoTransferV4Handshake.sessionKey(key: key, nonceS: "AAAAAAAAAAAAAAAAAAAAAA", nonceR: "CCCCCCCCCCCCCCCCCCCCCC")
        let c = PhotoTransferV4Handshake.sessionKey(key: PhotoTransferV4Handshake.handshakeKey(token: token + "x"),
                                                    nonceS: "AAAAAAAAAAAAAAAAAAAAAA", nonceR: "BBBBBBBBBBBBBBBBBBBBBB")
        func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
        XCTAssertNotEqual(bytes(a), bytes(b))
        XCTAssertNotEqual(bytes(a), bytes(c))
        XCTAssertEqual(bytes(a).count, 32)
    }

    func testV4LineParsersAreStrict() {
        let n = "AAAAAAAAAAAAAAAAAAAAAA"
        XCTAssertNil(PhotoTransferV4Handshake.parseHello("NASFINDER_PHOTO/4 hello ios grouped-v1 receipt-v1"), "nonce가 없으면 거부")
        XCTAssertNil(PhotoTransferV4Handshake.parseHello("NASFINDER_PHOTO/4 hello ios grouped-v1 receipt-v1 \(n) extra"))
        XCTAssertNil(PhotoTransferV4Handshake.parseHello("NASFINDER_PHOTO/4 hello windows grouped-v1 receipt-v1 \(n)"))
        XCTAssertNil(PhotoTransferV4Handshake.parseHello("NASFINDER_PHOTO/4 hello ios receipt-v1 grouped-v1 \(n)"))
        XCTAssertNil(PhotoTransferV4Handshake.parseHello("NASFINDER_PHOTO/4 hello ios grouped-v1 receipt-v1 short"))
        XCTAssertNil(PhotoTransferV4Handshake.parseHello("NASFINDER_PHOTO/4  hello ios grouped-v1 receipt-v1 \(n)"), "연속 공백 거부")
        XCTAssertNotNil(PhotoTransferV4Handshake.parseHello("NASFINDER_PHOTO/4 hello ios grouped-v1 receipt-v1 \(n)\r"), "선택적 \\r 허용")
        XCTAssertNil(PhotoTransferV4Handshake.parseChallenge("CHALLENGE"))
        XCTAssertNil(PhotoTransferV4Handshake.parseProof("PROOF ABC"))
        XCTAssertNil(PhotoTransferV4Handshake.parseProof("PROOF " + String(repeating: "AB", count: 32)), "대문자 hex 거부")
        XCTAssertNil(PhotoTransferV4Handshake.parseOK("OK ios grouped-v1 receipt-v1"))
        XCTAssertNil(PhotoTransferV4Handshake.parseOK("OK ios grouped-v1"))
    }

    func testV3HandshakeIsUnchangedAndStillRejectsV4Lines() {
        XCTAssertEqual(PhotoTransferHandshake.clientLine(token: token), "NASFINDER_PHOTO/3 \(token) ios grouped-v1\n")
        let v3 = PhotoTransferHandshake.decision(toClientLine: "NASFINDER_PHOTO/3 \(token) android grouped-v1", expectedToken: token)
        XCTAssertEqual(v3.response, "OK ios grouped-v1\n")
        // v4 hello는 v3 결정 함수가 처리하지 않는다(수신 세션이 먼저 가로챔). 모르는 버전으로 거부되어 토큰·리스너는 유지된다.
        let rejected = PhotoTransferHandshake.decision(
            toClientLine: "NASFINDER_PHOTO/4 hello ios grouped-v1 receipt-v1 AAAAAAAAAAAAAAAAAAAAAA", expectedToken: token)
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.response, PhotoTransferHandshake.rejectResponse)
    }

    // MARK: 프레임

    func testBeginFrameRoundTripAndStrictKeys() throws {
        let frame = try PhotoTransferControlCodec.beginFrame(.init(transferId: transferId, itemCount: 3))
        var buffer = PhotoTransferControlFrameBuffer()
        buffer.append(frame)
        let json = try XCTUnwrap(try buffer.nextJSON())
        let object = try XCTUnwrap(PhotoTransferControlCodec.jsonObject(json))
        XCTAssertEqual(PhotoTransferControlCodec.decodeBegin(object), PhotoTransferBeginFrame(transferId: transferId, itemCount: 3))
        var extra = object
        extra["unexpected"] = 1
        XCTAssertNil(PhotoTransferControlCodec.decodeBegin(extra))
        var zero = object
        zero["itemCount"] = 0
        XCTAssertNil(PhotoTransferControlCodec.decodeBegin(zero))
        var tooMany = object
        tooMany["itemCount"] = 10_001
        XCTAssertNil(PhotoTransferControlCodec.decodeBegin(tooMany))
        var boolCount = object
        boolCount["itemCount"] = true
        XCTAssertNil(PhotoTransferControlCodec.decodeBegin(boolCount))
        XCTAssertThrowsError(try PhotoTransferControlCodec.beginFrame(.init(transferId: "short", itemCount: 1)))
    }

    private var sessionKey: SymmetricKey {
        PhotoTransferV4Handshake.sessionKey(key: PhotoTransferV4Handshake.handshakeKey(token: token),
                                            nonceS: "AAAAAAAAAAAAAAAAAAAAAA", nonceR: "BBBBBBBBBBBBBBBBBBBBBB")
    }

    private func decodeAll(_ frames: [Data]) throws -> [PhotoTransferReceiptFrame] {
        var buffer = PhotoTransferControlFrameBuffer()
        frames.forEach { buffer.append($0) }
        var decoded: [PhotoTransferReceiptFrame] = []
        while let json = try buffer.nextJSON() {
            let object = try XCTUnwrap(PhotoTransferControlCodec.jsonObject(json))
            decoded.append(try XCTUnwrap(PhotoTransferControlCodec.decodeReceipt(object)))
        }
        return decoded
    }

    func testReceiptFramesSplitAtOneHundredTwentyEightItemsWithSequenceAndMAC() throws {
        let items = (0..<130).map { index in
            PhotoTransferReceiptItem(itemId: "item\(index)", state: .committed,
                                     inputs: [.init(index: 0, sha256: sha)], reason: nil)
        }
        let key = sessionKey
        let result = try PhotoTransferControlCodec.receiptFrames(
            stage: .final, transferId: transferId, receiverId: receiverId, status: .complete,
            items: items, sessionKey: key, startingSeq: 3)
        XCTAssertEqual(result.frames.count, 2)
        XCTAssertEqual(result.nextSeq, 5)
        let decoded = try decodeAll(result.frames)
        XCTAssertEqual(decoded.map(\.items.count), [128, 2])
        XCTAssertEqual(decoded.map(\.more), [true, false])
        XCTAssertEqual(decoded.map(\.seq), [3, 4])
        XCTAssertEqual(decoded.flatMap(\.items), items)
        XCTAssertTrue(decoded.allSatisfy { PhotoTransferControlCodec.verifyMAC(of: $0, key: key) })
    }

    func testCanonicalReceiptStringMatchesTheContractLayout() {
        let items = [
            PhotoTransferReceiptItem(itemId: "b-item", state: .failed, inputs: [], reason: "storage"),
            PhotoTransferReceiptItem(itemId: "a-item", state: .committed,
                                     inputs: [.init(index: 1, sha256: String(repeating: "cd", count: 32)),
                                              .init(index: 0, sha256: sha)], reason: nil),
        ]
        let canonical = PhotoTransferControlCodec.canonicalReceipt(
            stage: .final, transferId: transferId, receiverId: receiverId, status: .partial, more: false, seq: 2, items: items)
        let expected = [
            "receipt", "final", transferId, receiverId, "partial", "false", "2",
            "a-item|committed|0:\(sha),1:\(String(repeating: "cd", count: 32))|-",
            "b-item|failed||storage",
        ].joined(separator: "\n")
        XCTAssertEqual(canonical, expected, "항목은 itemId 오름차순, 입력은 index 오름차순, 끝에 추가 줄바꿈 없음.")
        let noStatus = PhotoTransferControlCodec.canonicalReceipt(
            stage: .ready, transferId: transferId, receiverId: receiverId, status: nil, more: true, seq: 1, items: [])
        XCTAssertEqual(noStatus, ["receipt", "ready", transferId, receiverId, "-", "true", "1"].joined(separator: "\n"))
    }

    func testReceiptMACRejectsAnyTamperingOrWrongKey() throws {
        let items = [PhotoTransferReceiptItem(itemId: "a", state: .committed, inputs: [.init(index: 0, sha256: sha)], reason: nil)]
        let key = sessionKey
        let frame = try decodeAll(try PhotoTransferControlCodec.receiptFrames(
            stage: .final, transferId: transferId, receiverId: receiverId, status: .complete,
            items: items, sessionKey: key, startingSeq: 1).frames)[0]
        XCTAssertTrue(PhotoTransferControlCodec.verifyMAC(of: frame, key: key))
        let otherKey = PhotoTransferV4Handshake.sessionKey(key: PhotoTransferV4Handshake.handshakeKey(token: token),
                                                           nonceS: "AAAAAAAAAAAAAAAAAAAAAA", nonceR: "CCCCCCCCCCCCCCCCCCCCCC")
        XCTAssertFalse(PhotoTransferControlCodec.verifyMAC(of: frame, key: otherKey), "다른 nonce 쌍의 세션 키로는 통과하면 안 됩니다.")
        func tampered(_ change: (PhotoTransferReceiptFrame) -> PhotoTransferReceiptFrame) -> PhotoTransferReceiptFrame { change(frame) }
        let flippedState = tampered { PhotoTransferReceiptFrame(stage: $0.stage, transferId: $0.transferId, receiverId: $0.receiverId, status: $0.status, more: $0.more, seq: $0.seq,
            items: [.init(itemId: "a", state: .failed, inputs: $0.items[0].inputs, reason: "storage")], mac: $0.mac) }
        XCTAssertFalse(PhotoTransferControlCodec.verifyMAC(of: flippedState, key: key))
        let otherSeq = tampered { PhotoTransferReceiptFrame(stage: $0.stage, transferId: $0.transferId, receiverId: $0.receiverId, status: $0.status, more: $0.more, seq: 2, items: $0.items, mac: $0.mac) }
        XCTAssertFalse(PhotoTransferControlCodec.verifyMAC(of: otherSeq, key: key), "재전송·재배열을 순번이 막습니다.")
        let otherHash = tampered { PhotoTransferReceiptFrame(stage: $0.stage, transferId: $0.transferId, receiverId: $0.receiverId, status: $0.status, more: $0.more, seq: $0.seq,
            items: [.init(itemId: "a", state: .committed, inputs: [.init(index: 0, sha256: String(repeating: "cd", count: 32))], reason: nil)], mac: $0.mac) }
        XCTAssertFalse(PhotoTransferControlCodec.verifyMAC(of: otherHash, key: key))
        let otherTransfer = tampered { PhotoTransferReceiptFrame(stage: $0.stage, transferId: "ffffffffffffffffffffffffffffffff", receiverId: $0.receiverId, status: $0.status, more: $0.more, seq: $0.seq, items: $0.items, mac: $0.mac) }
        XCTAssertFalse(PhotoTransferControlCodec.verifyMAC(of: otherTransfer, key: key))
    }

    func testReceiptDecodingRejectsUnknownKeysBadHashesAndReasons() throws {
        let key = sessionKey
        let frames = try PhotoTransferControlCodec.receiptFrames(
            stage: .ready, transferId: transferId, receiverId: receiverId, status: nil,
            items: [.init(itemId: "a", state: .failed, inputs: [], reason: "storage")], sessionKey: key, startingSeq: 1).frames
        var buffer = PhotoTransferControlFrameBuffer()
        buffer.append(frames[0])
        let object = try XCTUnwrap(PhotoTransferControlCodec.jsonObject(try XCTUnwrap(try buffer.nextJSON())))
        XCTAssertNotNil(PhotoTransferControlCodec.decodeReceipt(object))
        var unknownKey = object
        unknownKey["extra"] = true
        XCTAssertNil(PhotoTransferControlCodec.decodeReceipt(unknownKey))
        var withOutput = object
        withOutput["items"] = [["itemId": "a", "state": "committed", "output": ["kind": "photos", "id": "x"]]]
        XCTAssertNil(PhotoTransferControlCodec.decodeReceipt(withOutput), "수신 자산 식별자는 와이어에 없습니다(개정 2).")
        var missingMAC = object
        missingMAC.removeValue(forKey: "mac")
        XCTAssertNil(PhotoTransferControlCodec.decodeReceipt(missingMAC))
        var missingSeq = object
        missingSeq.removeValue(forKey: "seq")
        XCTAssertNil(PhotoTransferControlCodec.decodeReceipt(missingSeq))
        var zeroSeq = object
        zeroSeq["seq"] = 0
        XCTAssertNil(PhotoTransferControlCodec.decodeReceipt(zeroSeq))
        var badReason = object
        badReason["items"] = [["itemId": "a", "state": "failed", "reason": "free text"]]
        XCTAssertNil(PhotoTransferControlCodec.decodeReceipt(badReason))
        var badHash = object
        badHash["items"] = [["itemId": "a", "state": "committed", "inputs": [["index": 0, "sha256": "ABC"]]]]
        XCTAssertNil(PhotoTransferControlCodec.decodeReceipt(badHash))
        var duplicate = object
        duplicate["items"] = [["itemId": "a", "state": "failed"], ["itemId": "a", "state": "failed"]]
        XCTAssertNil(PhotoTransferControlCodec.decodeReceipt(duplicate))
    }

    func testControlFrameBufferRejectsZeroAndOversizedLengthsBeforeAllocating() {
        var zero = PhotoTransferControlFrameBuffer()
        zero.append(Data([0, 0, 0, 0]))
        XCTAssertThrowsError(try zero.nextJSON())
        var huge = PhotoTransferControlFrameBuffer()
        huge.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertThrowsError(try huge.nextJSON())
        var partial = PhotoTransferControlFrameBuffer()
        partial.append(Data([0, 0, 0, 10, 1, 2]))
        XCTAssertNil(try partial.nextJSON())
    }

    func testStreamingDecoderOnlyAcceptsBeginAfterV4Authentication() throws {
        let begin = try PhotoTransferControlCodec.beginFrame(.init(transferId: transferId, itemCount: 1))
        var legacy = PhotoTransferStreamingWireDecoder()
        XCTAssertThrowsError(try legacy.append(begin))
        var v4 = PhotoTransferStreamingWireDecoder()
        v4.acceptsControlFrames = true
        let events = try v4.append(begin)
        guard case .begin(let parsed)? = events.first else { return XCTFail("begin 이벤트가 필요합니다.") }
        XCTAssertEqual(parsed.itemCount, 1)
        // 수신이 보내는 receipt 프레임은 수신 쪽 파일 디코더에 들어오면 안 된다.
        let receipt = try PhotoTransferControlCodec.receiptFrames(
            stage: .ready, transferId: transferId, receiverId: receiverId, status: nil, items: [],
            sessionKey: sessionKey, startingSeq: 1).frames[0]
        var strict = PhotoTransferStreamingWireDecoder()
        strict.acceptsControlFrames = true
        XCTAssertThrowsError(try strict.append(receipt))
    }

    func testIdentifierRules() {
        XCTAssertTrue(PhotoTransferReceiptWire.isValidItemID(UUID().uuidString))
        XCTAssertFalse(PhotoTransferReceiptWire.isValidItemID(""))
        XCTAssertFalse(PhotoTransferReceiptWire.isValidItemID("bad/id"))
        XCTAssertFalse(PhotoTransferReceiptWire.isValidItemID(String(repeating: "a", count: 65)))
        XCTAssertTrue(PhotoTransferReceiptWire.isValidTransferID(UUID().uuidString))
        XCTAssertFalse(PhotoTransferReceiptWire.isValidTransferID("short"))
        XCTAssertTrue(PhotoTransferReceiptWire.isValidNonce("AAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertFalse(PhotoTransferReceiptWire.isValidNonce("AAAAA"))
    }

    // MARK: 입력 해시 대조

    func testInputsMatchRequiresExactIndexAndHashSet() {
        let a = PhotoTransferReceiptInput(index: 0, sha256: sha)
        let b = PhotoTransferReceiptInput(index: 1, sha256: String(repeating: "cd", count: 32))
        XCTAssertTrue(PhotoTransferSenderSession.inputsMatch([b, a], [a, b]))
        XCTAssertFalse(PhotoTransferSenderSession.inputsMatch([a], [a, b]), "Live/Motion은 모든 구성요소가 있어야 합니다.")
        XCTAssertFalse(PhotoTransferSenderSession.inputsMatch([a, PhotoTransferReceiptInput(index: 1, sha256: sha)], [a, b]))
        XCTAssertFalse(PhotoTransferSenderSession.inputsMatch([], []), "비어 있는 기대값은 검증이 아닙니다.")
    }

    // MARK: 수신 저널

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nasfinder-journal-test-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReceiptJournalIsIdempotentAndSurvivesRestart() throws {
        let directory = temporaryDirectory()
        let input = PhotoTransferReceiptInput(index: 0, sha256: sha)
        let journal = PhotoTransferReceiptJournal(directory: directory)
        let receiver = journal.receiverId
        XCTAssertTrue(PhotoTransferReceiptWire.isValidReceiverID(receiver))
        XCTAssertTrue(try journal.reserve(transferId: transferId, itemId: "item1", inputs: [input], placeholderIdentifiers: ["PH/L0/001"]))
        try journal.markCommitted(transferId: transferId, itemId: "item1", outputIdentifiers: ["PH/L0/001"])
        XCTAssertFalse(try journal.reserve(transferId: transferId, itemId: "item1", inputs: [input], placeholderIdentifiers: ["OTHER"]),
                       "이미 저장된 항목은 다시 예약하지 않습니다.")
        journal.markFailed(transferId: transferId, itemId: "item1", inputs: [input], reason: "storage")
        XCTAssertEqual(journal.entry(transferId: transferId, itemId: "item1")?.state, .committed, "committed는 실패로 되돌리지 않습니다.")

        let reloaded = PhotoTransferReceiptJournal(directory: directory)
        XCTAssertEqual(reloaded.receiverId, receiver, "수신자 ID는 재시작 후에도 같아야 합니다.")
        XCTAssertEqual(reloaded.entry(transferId: transferId, itemId: "item1")?.outputIdentifiers, ["PH/L0/001"])
    }

    // MARK: 출력 무결성(작성만, 실행 안 함)

    private func proof(_ id: String, kind: String = "photo", parts: [(Int, String)] = [(1, "aa")]) -> PhotoTransferOutputProof {
        PhotoTransferOutputProof(identifier: id, kind: kind,
                                 parts: parts.map { .init(resourceType: $0.0, sha256: $0.1, byteLength: 10) })
    }

    func testCommittedWithValidOutputProofIsQualifiedAndInputHashIsSeparate() {
        let saved = proof("A", parts: [(1, "out-hash-differs-from-input")])
        let entry = PhotoTransferReceiptJournal.Entry(
            transferId: transferId, itemId: "i1", state: .committed, inputs: [.init(index: 0, sha256: sha)],
            outputIdentifiers: ["A"], reason: nil, updatedAt: Date(), outputProofs: [saved])
        let check = PhotoTransferOutputProofing.evaluate(outputIdentifiers: ["A"], saved: [saved], states: ["A": .present(saved)])
        XCTAssertEqual(check, .verified, "변환된 출력은 입력 해시와 달라도 저장 직후 출력 증명과 같으면 검증됩니다.")
        let item = PhotoTransferReceiverSession.receiptItem(from: entry, check: check)
        XCTAssertEqual(item.state, .committed)
        XCTAssertEqual(item.inputs, [.init(index: 0, sha256: sha)], "와이어에는 입력 해시만 실리고 출력 증명·자산 ID는 없습니다.")
    }

    func testDeletedModifiedOrUnverifiableOutputIsWithheldFromCommittedReceipt() {
        let saved = proof("A")
        let states: [(PhotoTransferOutputState, PhotoTransferOutputCheck, String)] = [
            (.absent, .missing, "outmissing"),
            (.present(proof("A", parts: [(1, "bb")])), .modified, "outmodified"),
            (.present(proof("A", parts: [(1, "aa"), (6, "cc")])), .modified, "outmodified"),
            (.unreadable, .unverifiable, "outunverified"),
        ]
        for (state, expected, reason) in states {
            let check = PhotoTransferOutputProofing.evaluate(outputIdentifiers: ["A"], saved: [saved], states: ["A": state])
            XCTAssertEqual(check, expected)
            let entry = PhotoTransferReceiptJournal.Entry(
                transferId: transferId, itemId: "i1", state: .committed, inputs: [.init(index: 0, sha256: sha)],
                outputIdentifiers: ["A"], reason: nil, updatedAt: Date(), outputProofs: [saved])
            let item = PhotoTransferReceiverSession.receiptItem(from: entry, check: check)
            XCTAssertEqual(item.state, .failed)
            XCTAssertEqual(item.reason, reason)
            XCTAssertTrue(PhotoTransferReceiptWire.isValidReason(reason))
        }
        XCTAssertEqual(PhotoTransferOutputProofing.evaluate(outputIdentifiers: ["A"], saved: nil, states: ["A": .present(saved)]),
                       .unverifiable, "증명이 없는 기존 기록은 유효하다고 가정하지 않습니다.")
        XCTAssertEqual(PhotoTransferOutputProofing.evaluate(outputIdentifiers: ["A", "B"], saved: [saved, proof("B")],
                                                            states: ["A": .present(saved), "B": .absent]),
                       .missing, "Live/Motion 등 일부 자산·부분이 빠지면 검증되지 않습니다.")
    }

    func testReservedWithoutExactProofStaysUnresolvedAndNeverPromotedFromPresenceAlone() {
        let current = proof("P", parts: [(1, "aa"), (9, "bb")])
        let exact = [PhotoTransferPlannedOutput(identifier: "P", kind: "photo", parts: [.init(resourceType: 1, inputSha256: "aa"), .init(resourceType: 9, inputSha256: "bb")])]
        XCTAssertEqual(PhotoTransferOutputProofing.resolveReservation(outputIdentifiers: ["P"], planned: exact, states: ["P": .present(current)]),
                       .promote([current]))
        let converted = [PhotoTransferPlannedOutput(identifier: "P", kind: "photo", parts: [.init(resourceType: 1, inputSha256: nil), .init(resourceType: 9, inputSha256: "bb")])]
        XCTAssertEqual(PhotoTransferOutputProofing.resolveReservation(outputIdentifiers: ["P"], planned: converted, states: ["P": .present(current)]),
                       .unresolved, "존재만으로 승격하지 않고, 변환된 부분은 정확 증명이 없으면 미해결입니다.")
        XCTAssertEqual(PhotoTransferOutputProofing.resolveReservation(outputIdentifiers: ["P"], planned: nil, states: ["P": .present(current)]), .unresolved)
        XCTAssertEqual(PhotoTransferOutputProofing.resolveReservation(outputIdentifiers: ["P"], planned: exact, states: ["P": .unreadable]), .unresolved)
        XCTAssertEqual(PhotoTransferOutputProofing.resolveReservation(outputIdentifiers: ["P"], planned: exact, states: ["P": .absent]), .revert)
    }

    func testJournalAppliesResolutionsWithoutTouchingUnresolvedOrCommittedEntries() throws {
        let journal = PhotoTransferReceiptJournal(directory: temporaryDirectory())
        let input = PhotoTransferReceiptInput(index: 0, sha256: sha)
        _ = try journal.reserve(transferId: transferId, itemId: "saved", inputs: [input], placeholderIdentifiers: ["A"])
        _ = try journal.reserve(transferId: transferId, itemId: "gone", inputs: [input], placeholderIdentifiers: ["B"])
        _ = try journal.reserve(transferId: transferId, itemId: "unknown", inputs: [input], placeholderIdentifiers: ["C"])
        let p = proof("A")
        XCTAssertTrue(journal.applyResolution(transferId: transferId, itemId: "saved", .promote([p])))
        XCTAssertTrue(journal.applyResolution(transferId: transferId, itemId: "gone", .revert))
        XCTAssertFalse(journal.applyResolution(transferId: transferId, itemId: "unknown", .unresolved))
        XCTAssertEqual(journal.entry(transferId: transferId, itemId: "saved")?.state, .committed)
        XCTAssertEqual(journal.entry(transferId: transferId, itemId: "saved")?.outputProofs, [p])
        XCTAssertNil(journal.entry(transferId: transferId, itemId: "gone"))
        XCTAssertEqual(journal.entry(transferId: transferId, itemId: "unknown")?.state, .reserved, "확인 불가 예약은 그대로 남습니다.")
        XCTAssertFalse(journal.applyResolution(transferId: transferId, itemId: "saved", .revert), "committed 항목은 되돌리지 않습니다.")
        XCTAssertEqual(PhotoTransferReceiptJournal(directory: temporaryDirectory()).reservedEntries().count, 0)
    }

    func testExpiryRemovesOnlyOldJournalEntriesNeverReservations() throws {
        let journal = PhotoTransferReceiptJournal(directory: temporaryDirectory())
        let input = PhotoTransferReceiptInput(index: 0, sha256: sha)
        _ = try journal.reserve(transferId: transferId, itemId: "old", inputs: [input], placeholderIdentifiers: ["A"])
        try journal.markCommitted(transferId: transferId, itemId: "old", outputIdentifiers: ["A"])
        _ = try journal.reserve(transferId: transferId, itemId: "pending", inputs: [input], placeholderIdentifiers: ["B"])
        journal.expireOldEntries(now: Date().addingTimeInterval(PhotoTransferReceiptJournal.retention + 60))
        XCTAssertNil(journal.entry(transferId: transferId, itemId: "old"))
        XCTAssertEqual(journal.entry(transferId: transferId, itemId: "pending")?.state, .reserved)
    }

    // MARK: 발신 계획과 삭제 자격

    func testSenderPlanKeepsStableIDsAcrossRetriesForTheSameSelection() {
        let journal = PhotoTransferSenderJournal(directory: temporaryDirectory())
        let first = journal.planForSending(identifiers: ["a", "b"], kinds: [.photo, .livePhoto])
        let second = journal.planForSending(identifiers: ["a", "b"], kinds: [.photo, .livePhoto])
        XCTAssertEqual(first.transferId, second.transferId)
        XCTAssertEqual(first.items.map(\.itemId), second.items.map(\.itemId))
        let different = journal.planForSending(identifiers: ["a", "c"], kinds: [.photo, .photo])
        XCTAssertNotEqual(first.transferId, different.transferId)
        let ephemeral = journal.planForSending(identifiers: ["a", nil], kinds: [.photo, .photo])
        XCTAssertNil(ephemeral.selectionKey, "식별자를 모르는 선택은 계획을 저널에서 이어 쓰지 않습니다.")
    }

    func testSenderJournalPersistsAcrossRestartWithTheSameIDs() {
        let directory = temporaryDirectory()
        let plan = PhotoTransferSenderJournal(directory: directory).planForSending(identifiers: ["x"], kinds: [.photo])
        let reloaded = PhotoTransferSenderJournal(directory: directory).planForSending(identifiers: ["x"], kinds: [.photo])
        XCTAssertEqual(plan.transferId, reloaded.transferId)
        XCTAssertEqual(plan.items.map(\.itemId), reloaded.items.map(\.itemId))
    }

    func testFullyVerifiedPlanStartsANewTransferNextTime() {
        let journal = PhotoTransferSenderJournal(directory: temporaryDirectory())
        var plan = journal.planForSending(identifiers: ["a"], kinds: [.photo])
        plan.items[0].status = .verified
        journal.update(plan)
        let next = journal.planForSending(identifiers: ["a"], kinds: [.photo])
        XCTAssertNotEqual(plan.transferId, next.transferId)
    }

    func testOutputBlockedItemsAreExcludedFromSameTransferRetry() {
        let journal = PhotoTransferSenderJournal(directory: temporaryDirectory())
        var plan = journal.planForSending(identifiers: ["a", "b", "c"], kinds: [.photo, .photo, .photo])
        plan.items[0].status = .verified
        plan.items[1].status = .failed
        plan.items[1].blockedReasonCode = "outmissing"
        plan.items[2].status = .failed
        plan.items[2].blockedReasonCode = "checksum"
        journal.update(plan)
        let reloaded = journal.planForSending(identifiers: ["a", "b", "c"], kinds: [.photo, .photo, .photo])
        XCTAssertEqual(reloaded.transferId, plan.transferId)
        XCTAssertEqual(reloaded.outputBlockedItems.map(\.itemId), [plan.items[1].itemId], "출력 실패 코드만 재시도에서 제외됩니다.")
        XCTAssertFalse(PhotoTransferSenderSession.reasonText("outmodified").isEmpty)
    }

    func testExplicitNewTransferHasNewIDsAndInheritsNoVerification() {
        let journal = PhotoTransferSenderJournal(directory: temporaryDirectory())
        var old = journal.planForSending(identifiers: ["a", "b"], kinds: [.photo, .photo])
        old.items[0].status = .failed
        old.items[0].blockedReasonCode = "outmodified"
        old.items[0].expectedInputs = [PhotoTransferReceiptInput(index: 0, sha256: sha)]
        journal.update(old)
        let fresh = journal.planForNewTransfer(superseding: old.transferId, identifiers: ["a"], kinds: [.photo])
        XCTAssertNotEqual(fresh.transferId, old.transferId)
        XCTAssertNotEqual(fresh.items[0].itemId, old.items[0].itemId)
        XCTAssertEqual(fresh.items[0].status, .pending)
        XCTAssertNil(fresh.items[0].blockedReasonCode)
        XCTAssertTrue(fresh.items[0].expectedInputs.isEmpty)
        XCTAssertEqual(journal.plan(transferId: old.transferId)?.supersededBy, fresh.transferId, "이전 계획은 지우지 않고 대체됨으로만 표시합니다.")
        XCTAssertEqual(journal.planForSending(identifiers: ["a"], kinds: [.photo]).transferId, fresh.transferId)
    }

    @MainActor
    func testDeletionEligibilityExcludesEverythingExceptVerifiedExactSourceWithReceipts() {
        let snapshot = PhotoTransferSourceSnapshot(
            assetLocalIdentifier: "ID", creationDate: nil, modificationDate: nil,
            resources: [.init(typeRawValue: 1, originalFilename: "IMG_1.HEIC", uniformTypeIdentifier: "public.heic")],
            allResourceTypeRawValues: [1])
        func item(_ status: PhotoTransferSenderPlan.Item.Status, snapshot: PhotoTransferSourceSnapshot? = snapshot,
                  inputs: [PhotoTransferReceiptInput] = [.init(index: 0, sha256: String(repeating: "ab", count: 32))]) -> PhotoTransferSenderPlan.Item {
            .init(itemId: "i", position: 0, pickerIdentifier: "ID", kindRawValue: "photo", expectedInputs: inputs,
                  snapshot: snapshot, status: status, reason: nil)
        }
        XCTAssertEqual(PhotoTransferSourceVerifier.preliminaryEligibility(of: item(.verified), receiptsNegotiated: true), .candidate)
        for status in [PhotoTransferSenderPlan.Item.Status.pending, .failed, .unknown, .legacyAcknowledged] {
            XCTAssertFalse(PhotoTransferSourceVerifier.preliminaryEligibility(of: item(status), receiptsNegotiated: true).isCandidate, "\(status)")
        }
        XCTAssertFalse(PhotoTransferSourceVerifier.preliminaryEligibility(of: item(.verified), receiptsNegotiated: false).isCandidate,
                       "항목별 영수증이 협상되지 않은 상대는 삭제 자격이 없습니다.")
        XCTAssertFalse(PhotoTransferSourceVerifier.preliminaryEligibility(of: item(.verified, snapshot: nil), receiptsNegotiated: true).isCandidate,
                       "정확한 PHAsset 출처가 없으면(파일 복사본·선택기 임시 파일) 삭제 대상이 아닙니다.")
        XCTAssertFalse(PhotoTransferSourceVerifier.preliminaryEligibility(of: item(.verified, inputs: []), receiptsNegotiated: true).isCandidate)
        let mismatchedCount = item(.verified, inputs: [.init(index: 0, sha256: String(repeating: "ab", count: 32)), .init(index: 1, sha256: String(repeating: "cd", count: 32))])
        XCTAssertFalse(PhotoTransferSourceVerifier.preliminaryEligibility(of: mismatchedCount, receiptsNegotiated: true).isCandidate,
                       "Live/Motion은 모든 구성요소 해시가 원본 자원 수와 맞아야 합니다.")
    }

    // MARK: 안전 리뷰 수리(작성만, 실행 안 함)

    private func plan(statuses: [PhotoTransferSenderPlan.Item.Status], inputs: [PhotoTransferReceiptInput]? = nil) -> PhotoTransferSenderPlan {
        let expected = inputs ?? [PhotoTransferReceiptInput(index: 0, sha256: sha)]
        var plan = PhotoTransferSenderPlan.make(identifiers: statuses.indices.map { "p\($0)" }, kinds: statuses.map { _ in .photo })
        for index in statuses.indices {
            plan.items[index].status = statuses[index]
            plan.items[index].expectedInputs = expected
        }
        return plan
    }

    private func committedItem(_ plan: PhotoTransferSenderPlan, _ index: Int) -> PhotoTransferReceiptItem {
        .init(itemId: plan.items[index].itemId, state: .committed, inputs: plan.items[index].expectedInputs, reason: nil)
    }

    func testFinalReceiptDowngradesPreviouslyVerifiedItemsInsteadOfBypassingThem() {
        var p = plan(statuses: [.verified, .verified, .verified, .verified])
        let received: [PhotoTransferReceiptItem] = [
            committedItem(p, 0),
            .init(itemId: p.items[1].itemId, state: .failed, inputs: p.items[1].expectedInputs, reason: "outmissing"),
            .init(itemId: p.items[2].itemId, state: .failed, inputs: p.items[2].expectedInputs, reason: "outmodified"),
            // items[3]은 final에 없다.
        ]
        PhotoTransferSenderSession.applyFinalReceipt(received, to: &p)
        XCTAssertEqual(p.items[0].status, .verified)
        XCTAssertEqual(p.items[1].status, .failed)
        XCTAssertEqual(p.items[1].blockedReasonCode, "outmissing")
        XCTAssertEqual(p.items[2].status, .failed)
        XCTAssertEqual(p.items[2].blockedReasonCode, "outmodified")
        XCTAssertEqual(p.items[3].status, .unknown, "final에 없는 이전 verified는 삭제 권위가 아닙니다.")
        XCTAssertEqual(p.outputBlockedItems.count, 2)
    }

    func testFinalReceiptConflictingDuplicatesAndWrongInputsFailClosed() {
        var p = plan(statuses: [.pending, .pending])
        let ok = committedItem(p, 0)
        let bad = PhotoTransferReceiptItem(itemId: p.items[0].itemId, state: .failed, inputs: [], reason: "conflict")
        let wrong = PhotoTransferReceiptItem(itemId: p.items[1].itemId, state: .committed, inputs: [.init(index: 0, sha256: String(repeating: "cd", count: 32))], reason: nil)
        PhotoTransferSenderSession.applyFinalReceipt([ok, bad, wrong], to: &p)
        XCTAssertEqual(p.items[0].status, .failed, "같은 항목에 실패 보고가 있으면 성공 보고가 있어도 실패입니다.")
        XCTAssertEqual(p.items[0].blockedReasonCode, "conflict", "미해소 예약은 같은 전송의 일반 재시도에서 제외됩니다.")
        XCTAssertEqual(p.items[1].status, .unknown)
    }

    @MainActor
    func testRestoredPlanNeverKeepsPreviousVerifiedAsCurrentDeletionAuthority() {
        var p = plan(statuses: [.verified, .failed, .legacyAcknowledged])
        p.items[1].blockedReasonCode = "outunverified"
        let requalified = PhotoTransferSenderSession.requalifiedForNewConnection(p)
        XCTAssertEqual(requalified.items.map(\.status), [.pending, .failed, .pending])
        XCTAssertEqual(requalified.items[1].blockedReasonCode, "outunverified", "출력 실패 판정은 유지됩니다.")
        XCTAssertFalse(requalified.isFullyVerified)
        for item in requalified.items {
            XCTAssertFalse(PhotoTransferSourceVerifier.preliminaryEligibility(of: item, receiptsNegotiated: true).isCandidate)
        }
        XCTAssertEqual(requalified.transferId, p.transferId, "안정 ID는 유지됩니다.")
    }

    func testReasonTextCoversOutputAndConflictReasons() {
        let unknown = PhotoTransferSenderSession.reasonText("zzz")
        for code in ["outmissing", "outmodified", "outunverified", "conflict"] {
            XCTAssertNotEqual(PhotoTransferSenderSession.reasonText(code), unknown, code)
        }
        XCTAssertTrue(PhotoTransferSenderPlan.outputBlockReasonCodes.contains("conflict"))
        XCTAssertFalse(PhotoTransferSenderPlan.outputBlockReasonCodes.contains("storage"))
    }

    @MainActor
    func testOnlySimpleFullOriginalShapesAreDeletionEligible() {
        let photo = 1, video = 2, fullSizePhoto = 5, adjustmentData = 7, pairedVideo = 9, fullSizePairedVideo = 10
        XCTAssertTrue(PhotoTransferSourceVerifier.isSupportedOriginalShape(whole: [photo], transferred: [photo]))
        XCTAssertTrue(PhotoTransferSourceVerifier.isSupportedOriginalShape(whole: [video], transferred: [video]))
        XCTAssertTrue(PhotoTransferSourceVerifier.isSupportedOriginalShape(whole: [pairedVideo, photo], transferred: [photo, pairedVideo]))
        // 편집본/추가 자원/조정 데이터가 있으면 전송한 원본만으로 자산 전체를 대신할 수 없다.
        XCTAssertFalse(PhotoTransferSourceVerifier.isSupportedOriginalShape(whole: [photo, fullSizePhoto, adjustmentData], transferred: [photo]))
        XCTAssertFalse(PhotoTransferSourceVerifier.isSupportedOriginalShape(whole: [photo, adjustmentData], transferred: [photo]))
        XCTAssertFalse(PhotoTransferSourceVerifier.isSupportedOriginalShape(whole: [video, 6], transferred: [video]))
        // Live Photo 한 구성요소만 보낸 경우(스틸만)는 제외.
        XCTAssertFalse(PhotoTransferSourceVerifier.isSupportedOriginalShape(whole: [photo, pairedVideo], transferred: [photo]))
        XCTAssertFalse(PhotoTransferSourceVerifier.isSupportedOriginalShape(whole: [fullSizePhoto, fullSizePairedVideo], transferred: [fullSizePhoto, fullSizePairedVideo]),
                       "지원하는 정확한 원본 구성만 허용합니다.")
        XCTAssertFalse(PhotoTransferSourceVerifier.isSupportedOriginalShape(whole: [photo, photo], transferred: [photo, photo]))
        XCTAssertFalse(PhotoTransferSourceVerifier.isSupportedOriginalShape(whole: [], transferred: []))

        XCTAssertNotNil(PhotoTransferSourceVerifier.layoutExclusionReason(snapshotWhole: nil, currentWhole: [photo], transferred: [photo]),
                        "전체 구성 스냅샷이 없는 이전 기록은 안전하게 제외합니다.")
        XCTAssertNotNil(PhotoTransferSourceVerifier.layoutExclusionReason(snapshotWhole: [photo], currentWhole: [photo, adjustmentData], transferred: [photo]),
                        "전송 뒤 편집으로 자원이 늘면 삭제 직전 재점검에서 제외합니다.")
        XCTAssertNil(PhotoTransferSourceVerifier.layoutExclusionReason(snapshotWhole: [photo], currentWhole: [photo], transferred: [photo]))
    }

    @MainActor
    func testLegacySnapshotWithoutWholeLayoutAndExtraResourceSnapshotAreExcludedByPreliminaryCheck() throws {
        func item(whole: [Int]?, transferred: [Int]) -> PhotoTransferSenderPlan.Item {
            let snapshot = PhotoTransferSourceSnapshot(
                assetLocalIdentifier: "ID", creationDate: nil, modificationDate: nil,
                resources: transferred.map { .init(typeRawValue: $0, originalFilename: "a", uniformTypeIdentifier: "public.heic") },
                allResourceTypeRawValues: whole)
            return .init(itemId: "i", position: 0, pickerIdentifier: "ID", kindRawValue: transferred.count == 2 ? "livePhoto" : "photo",
                         expectedInputs: transferred.indices.map { .init(index: $0, sha256: sha) }, snapshot: snapshot, status: .verified, reason: nil)
        }
        XCTAssertTrue(PhotoTransferSourceVerifier.preliminaryEligibility(of: item(whole: [1], transferred: [1]), receiptsNegotiated: true).isCandidate)
        XCTAssertTrue(PhotoTransferSourceVerifier.preliminaryEligibility(of: item(whole: [1, 9], transferred: [1, 9]), receiptsNegotiated: true).isCandidate)
        XCTAssertFalse(PhotoTransferSourceVerifier.preliminaryEligibility(of: item(whole: nil, transferred: [1]), receiptsNegotiated: true).isCandidate)
        XCTAssertFalse(PhotoTransferSourceVerifier.preliminaryEligibility(of: item(whole: [1, 5, 7], transferred: [1]), receiptsNegotiated: true).isCandidate)
        XCTAssertFalse(PhotoTransferSourceVerifier.preliminaryEligibility(of: item(whole: [1, 9], transferred: [1]), receiptsNegotiated: true).isCandidate)
        // 이전 버전이 저장한 JSON(키 없음)도 읽히고 제외된다.
        let legacyJSON = #"{"assetLocalIdentifier":"ID","resources":[{"typeRawValue":1,"originalFilename":"a","uniformTypeIdentifier":"public.heic"}]}"#
        let decoded = try JSONDecoder().decode(PhotoTransferSourceSnapshot.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.allResourceTypeRawValues)
    }

    private struct InjectedWriteFailure: Error {}

    private final class WriteGate: @unchecked Sendable {
        var fails = false
    }

    private func makeJournal(gate: WriteGate, directory: URL) -> PhotoTransferReceiptJournal {
        PhotoTransferReceiptJournal(directory: directory) { data, url in
            if gate.fails { throw InjectedWriteFailure() }
            try data.write(to: url, options: .atomic)
        }
    }

    func testJournalPersistenceFailureThrowsAndRollsBackInMemoryState() throws {
        let gate = WriteGate()
        let directory = temporaryDirectory()
        let journal = makeJournal(gate: gate, directory: directory)
        let input = PhotoTransferReceiptInput(index: 0, sha256: sha)

        gate.fails = true
        XCTAssertThrowsError(try journal.reserve(transferId: transferId, itemId: "a", inputs: [input], placeholderIdentifiers: ["P"]))
        XCTAssertNil(journal.entry(transferId: transferId, itemId: "a"), "쓰기 실패 시 메모리에 예약이 남으면 안 됩니다.")

        gate.fails = false
        XCTAssertTrue(try journal.reserve(transferId: transferId, itemId: "a", inputs: [input], placeholderIdentifiers: ["P"]))
        gate.fails = true
        XCTAssertThrowsError(try journal.markCommitted(transferId: transferId, itemId: "a", outputIdentifiers: ["P"], outputProofs: [proof("P")]))
        let entry = try XCTUnwrap(journal.entry(transferId: transferId, itemId: "a"))
        XCTAssertEqual(entry.state, .reserved, "commit 기록에 실패하면 메모리에서만 committed가 되지 않고 복구 가능한 예약으로 남습니다.")
        XCTAssertEqual(entry.outputIdentifiers, ["P"])
        XCTAssertNil(entry.outputProofs)
        XCTAssertEqual(PhotoTransferReceiptJournal(directory: directory).entry(transferId: transferId, itemId: "a")?.state, .reserved,
                       "디스크에도 예약이 남아 있습니다.")
    }

    func testMarkFailedNeverOverridesReservedOrCommittedIdentity() throws {
        let journal = PhotoTransferReceiptJournal(directory: temporaryDirectory())
        let input = PhotoTransferReceiptInput(index: 0, sha256: sha)
        let planned = [PhotoTransferPlannedOutput(identifier: "P", kind: "photo", parts: [.init(resourceType: 1, inputSha256: sha)])]
        _ = try journal.reserve(transferId: transferId, itemId: "r", inputs: [input], placeholderIdentifiers: ["P"], plannedOutputs: planned)
        XCTAssertFalse(journal.markFailed(transferId: transferId, itemId: "r", inputs: [input], reason: "invalid"))
        let reserved = try XCTUnwrap(journal.entry(transferId: transferId, itemId: "r"))
        XCTAssertEqual(reserved.state, .reserved)
        XCTAssertEqual(reserved.outputIdentifiers, ["P"])
        XCTAssertEqual(reserved.plannedOutputs, planned)
        XCTAssertTrue(journal.markFailed(transferId: transferId, itemId: "new", inputs: [input], reason: "storage"))
        XCTAssertEqual(journal.entry(transferId: transferId, itemId: "new")?.state, .failed)
    }

    func testPublishedOutputIsNotLostWhenResolutionCannotBePersisted() throws {
        let gate = WriteGate()
        let journal = makeJournal(gate: gate, directory: temporaryDirectory())
        let input = PhotoTransferReceiptInput(index: 0, sha256: sha)
        _ = try journal.reserve(transferId: transferId, itemId: "a", inputs: [input], placeholderIdentifiers: ["P"])
        gate.fails = true
        XCTAssertFalse(journal.applyResolution(transferId: transferId, itemId: "a", .promote([proof("P")])))
        XCTAssertFalse(journal.applyResolution(transferId: transferId, itemId: "a", .revert), "쓰기 실패 시 예약을 지우지 않습니다.")
        XCTAssertEqual(journal.entry(transferId: transferId, itemId: "a")?.state, .reserved)
        XCTAssertEqual(journal.entry(transferId: transferId, itemId: "a")?.outputIdentifiers, ["P"])
    }

    func testStoredButWrongUnconvertedBytesCannotQualifyAndTransformedPartsAreNotClaimedEqual() {
        let planned = [PhotoTransferPlannedOutput(identifier: "P", kind: "livePhoto", parts: [
            .init(resourceType: 1, inputSha256: sha),   // 변환 없음: 입력 해시와 같아야 한다.
            .init(resourceType: 9, inputSha256: nil),    // 변환됨: 입력과 같다고 주장하지 않는다.
        ])]
        let exact = proof("P", kind: "livePhoto", parts: [(1, sha), (9, "zz-converted")])
        let wrongStill = proof("P", kind: "livePhoto", parts: [(1, "deadbeef"), (9, "zz-converted")])
        let missingStill = proof("P", kind: "livePhoto", parts: [(9, "zz-converted")])
        XCTAssertTrue(PhotoTransferOutputProofing.unconvertedPartsMatchPlannedInputs(proofs: [exact], planned: planned))
        XCTAssertFalse(PhotoTransferOutputProofing.unconvertedPartsMatchPlannedInputs(proofs: [wrongStill], planned: planned),
                       "저장은 됐지만 입력과 다른 바이트면 verified 자격이 없습니다.")
        XCTAssertFalse(PhotoTransferOutputProofing.unconvertedPartsMatchPlannedInputs(proofs: [missingStill], planned: planned))
        XCTAssertFalse(PhotoTransferOutputProofing.unconvertedPartsMatchPlannedInputs(proofs: [], planned: planned))
        // 변환된 부분은 어떤 바이트여도 입력 비교에서 제외된다(그 부분의 verified는 '저장 직후와 같음'일 뿐).
        let otherConverted = proof("P", kind: "livePhoto", parts: [(1, sha), (9, "another")])
        XCTAssertTrue(PhotoTransferOutputProofing.unconvertedPartsMatchPlannedInputs(proofs: [otherConverted], planned: planned))
    }

    func testUnverifiableSavedItemIsReportedFailedWithOutputReasonNotSilentlyCommitted() {
        let entry = PhotoTransferReceiptJournal.Entry(
            transferId: transferId, itemId: "i", state: .committed, inputs: [.init(index: 0, sha256: sha)],
            outputIdentifiers: ["P"], reason: nil, updatedAt: Date(), outputProofs: nil)
        let item = PhotoTransferReceiverSession.receiptItem(from: entry, check: .unverifiable)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.reason, "outunverified")
        XCTAssertEqual(PhotoTransferReceiverSession.receiptItem(from: entry, check: .modified).reason, "outmodified")
        XCTAssertEqual(PhotoTransferReceiverSession.receiptItem(from: entry, check: .missing).reason, "outmissing")
        // 저널의 미해소 예약은 final에서 conflict로 보고되고, 발신은 이를 같은 전송 재시도에서 제외한다.
        var reserved = entry
        reserved.state = .reserved
        XCTAssertEqual(PhotoTransferReceiverSession.receiptItem(from: reserved, check: .unverifiable).reason, "conflict")
    }

    func testDeletionSelectionIsClearedWheneverTheResultSessionIdentityChanges() {
        let selected: Set<String> = ["a", "b"]
        XCTAssertEqual(PhotoTransferDeletionSelectionPolicy.reconciled(current: selected, previousEpoch: 3, currentEpoch: 4, candidateIDs: ["a", "b"]), [],
                       "재연결·새 전송·새 결과 세션에서는 이전에 체크한 항목을 이어받지 않습니다.")
        XCTAssertEqual(PhotoTransferDeletionSelectionPolicy.reconciled(current: selected, previousEpoch: 4, currentEpoch: 4, candidateIDs: ["a"]), ["a"],
                       "같은 세션에서도 삭제 후보가 아닌 항목은 선택에서 빠집니다.")
    }

    func testPhotoSelectionSaveSummaryCountsOnlyActuallyCreatedAssets() {
        let partial = PhotoSelectionActions.saveSummary(albumTitle: "앨범", existingCount: 1, requestedNewCount: 3, createdNewCount: 1)
        XCTAssertTrue(partial.contains("2장을 저장했습니다"), partial)
        XCTAssertTrue(partial.contains("2장은 앨범에 넣지 않았습니다"), partial)
        let none = PhotoSelectionActions.saveSummary(albumTitle: "앨범", existingCount: 0, requestedNewCount: 2, createdNewCount: 0)
        XCTAssertTrue(none.contains("아무것도 저장하지 못했습니다"), none)
        let full = PhotoSelectionActions.saveSummary(albumTitle: "앨범", existingCount: 2, requestedNewCount: 1, createdNewCount: 1)
        XCTAssertTrue(full.contains("3장을 저장했습니다"), full)
        XCTAssertFalse(full.contains("넣지 않았습니다"))
    }

    // MARK: 레거시 평문 노출 오염

    @MainActor
    func testTaintedTokenStaysTaintedAcrossStoreReloadAndBlocksDeletionEligibility() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoTransferTokenTaintStore(directory: directory)
        XCTAssertFalse(store.isTainted(token: token))
        store.markTainted(token: token)
        XCTAssertTrue(store.isTainted(token: token))
        XCTAssertFalse(store.isTainted(token: token + "x"), "다른 비밀은 오염되지 않습니다.")
        // 앱 재시작에 해당: 같은 폴더를 새로 열어도 유지된다.
        XCTAssertTrue(PhotoTransferTokenTaintStore(directory: directory).isTainted(token: token))
        let verified = PhotoTransferSenderPlan.Item(
            itemId: "i", position: 0, pickerIdentifier: "ID", kindRawValue: "photo",
            expectedInputs: [.init(index: 0, sha256: sha)],
            snapshot: .init(assetLocalIdentifier: "ID", creationDate: nil, modificationDate: nil,
                            resources: [.init(typeRawValue: 1, originalFilename: "IMG_1.HEIC", uniformTypeIdentifier: "public.heic")],
                            allResourceTypeRawValues: [1]),
            status: .verified, reason: nil)
        XCTAssertFalse(PhotoTransferSourceVerifier.preliminaryEligibility(
            of: verified, receiptsNegotiated: true, tokenExposed: true).isCandidate)
    }

    func testUnreadableTaintFileFailsClosedAndNeverReportsDurableMark() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taint-bad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("tainted.json"))
        let store = PhotoTransferTokenTaintStore(directory: directory)
        XCTAssertFalse(store.markTainted(token: token), "영속을 보장하지 못하면 false이고, 호출자는 평문을 보내지 않습니다.")
        XCTAssertTrue(store.isTainted(token: token))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("tainted.json")), Data("not json".utf8), "읽지 못한 파일을 덮어쓰지 않습니다.")
    }
}
