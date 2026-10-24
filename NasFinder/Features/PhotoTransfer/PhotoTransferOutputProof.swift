import CryptoKit
import Foundation
import Photos

/// 수신이 사진 보관함에 만든 출력 자산의 "지금 상태" 증명. 와이어에는 절대 싣지 않고 수신 저널에만 둔다.
/// 입력 해시(발신이 보낸 바이트)와는 별개다. 변환된 출력의 바이트는 입력 해시와 같을 필요가 없다.
struct PhotoTransferOutputProof: Codable, Equatable, Sendable {
    struct Part: Codable, Equatable, Sendable {
        var resourceType: Int
        var sha256: String
        var byteLength: UInt64
    }

    var identifier: String
    /// `photo` / `video` / `livePhoto`
    var kind: String
    /// resourceType 오름차순. 저장 직후 실제 자원 전체.
    var parts: [Part]
}

/// commit 직전에 저널에 남기는 계획. 크래시 뒤 `reserved`를 판정할 때만 쓴다.
/// `inputSha256`가 있는 부분은 바이트가 변환 없이 저장되는 부분이라 출력 해시와 정확히 비교할 수 있다. 없으면 정확 증명이 불가능하다.
struct PhotoTransferPlannedOutput: Codable, Equatable, Sendable {
    struct Part: Codable, Equatable, Sendable {
        var resourceType: Int
        var inputSha256: String?
    }

    var identifier: String
    var kind: String
    var parts: [Part]
}

enum PhotoTransferOutputCheck: Equatable, Sendable {
    case verified
    /// 출력 자산이 사진 보관함에 없다(사용자가 지웠을 수 있다).
    case missing
    /// 자원 구성이나 바이트가 저장 직후와 다르다.
    case modified
    /// 증명이 없거나 읽기 권한·자원 접근이 없어 확인하지 못했다.
    case unverifiable

    /// 영수증 `reason`(`^[A-Za-z0-9_]{1,16}$`). 확인된 경우는 nil.
    var receiptReason: String? {
        switch self {
        case .verified: nil
        case .missing: "outmissing"
        case .modified: "outmodified"
        case .unverifiable: "outunverified"
        }
    }
}

enum PhotoTransferOutputState: Equatable, Sendable {
    /// 읽기 권한이 충분했는데 식별자가 없다.
    case absent
    /// 읽기 권한이 없거나(제한 포함해 없음을 단정할 수 없음) 자원을 읽지 못했다.
    case unreadable
    case present(PhotoTransferOutputProof)
}

enum PhotoTransferReservationResolution: Equatable, Sendable {
    case promote([PhotoTransferOutputProof])
    /// 출력 자산이 없음이 확인됨 → 미커밋으로 되돌려 다시 받을 수 있다.
    case revert
    /// 확인 불가. 항목과 (있을 수 있는) 자산을 그대로 둔다.
    case unresolved
}

enum PhotoTransferOutputProofing {
    // MARK: 순수 판정(시험 대상)

    /// 저널의 저장 직후 증명과 현재 상태를 비교한다. 증명이 없는 기존 기록은 유효하다고 가정하지 않는다.
    static func evaluate(
        outputIdentifiers: [String],
        saved: [PhotoTransferOutputProof]?,
        states: [String: PhotoTransferOutputState]
    ) -> PhotoTransferOutputCheck {
        guard let saved, !saved.isEmpty, !outputIdentifiers.isEmpty,
              Set(saved.map(\.identifier)) == Set(outputIdentifiers),
              saved.count == outputIdentifiers.count else { return .unverifiable }
        var anyModified = false, anyMissing = false, anyUnverifiable = false
        for proof in saved {
            switch states[proof.identifier] ?? .unreadable {
            case .absent: anyMissing = true
            case .unreadable: anyUnverifiable = true
            case .present(let current): if current != proof { anyModified = true }
            }
        }
        if anyModified { return .modified }
        if anyMissing { return .missing }
        return anyUnverifiable ? .unverifiable : .verified
    }

    /// 앱이 멈춘 뒤 남은 `reserved`를 판정한다. 크기·존재만으로는 승격하지 않는다.
    /// 정확한 계획(종류, 자원 구성, 변환 없는 부분의 입력 해시 = 출력 해시)이 모두 맞을 때만 승격한다.
    static func resolveReservation(
        outputIdentifiers: [String],
        planned: [PhotoTransferPlannedOutput]?,
        states: [String: PhotoTransferOutputState]
    ) -> PhotoTransferReservationResolution {
        guard !outputIdentifiers.isEmpty else { return .unresolved }
        let current = outputIdentifiers.map { states[$0] ?? .unreadable }
        if current.allSatisfy({ $0 == .absent }) { return .revert }
        var proofs: [PhotoTransferOutputProof] = []
        for state in current {
            guard case .present(let proof) = state else { return .unresolved }
            proofs.append(proof)
        }
        guard let planned, planned.count == outputIdentifiers.count,
              planned.map(\.identifier) == outputIdentifiers else { return .unresolved }
        for (plan, proof) in zip(planned, proofs) {
            guard plan.kind == proof.kind,
                  plan.parts.map(\.resourceType).sorted() == proof.parts.map(\.resourceType) else { return .unresolved }
            for part in plan.parts {
                guard let expected = part.inputSha256,
                      let actual = proof.parts.first(where: { $0.resourceType == part.resourceType }),
                      actual.sha256 == expected else { return .unresolved }
            }
        }
        return .promote(proofs)
    }

    /// 저장 직후 출력이 보낸 입력과 같은지. 변환 없이 저장된 부분(`inputSha256`가 있는 부분)은 논리 부분(resourceType)과 해시가
    /// 계획의 입력과 정확히 같아야 한다. 변환된 부분(`inputSha256 == nil`)은 입력과 같다고 주장할 수 없으므로 이 비교에서 제외하고,
    /// 그 부분의 `verified`는 "저장 직후와 같다"는 뜻일 뿐이다. 하나라도 어긋나면 false라 committed 영수증 자격이 없다.
    static func unconvertedPartsMatchPlannedInputs(proofs: [PhotoTransferOutputProof], planned: [PhotoTransferPlannedOutput]) -> Bool {
        guard proofs.count == planned.count else { return false }
        for (proof, plan) in zip(proofs, planned) {
            for part in plan.parts {
                guard let expected = part.inputSha256 else { continue }
                guard let actual = proof.parts.first(where: { $0.resourceType == part.resourceType }),
                      actual.sha256 == expected else { return false }
            }
        }
        return true
    }

    // MARK: 실제 사진 보관함 읽기(알려진 식별자만, 보관함 전체 검색·새 권한 요청 없음)

    static func check(_ entry: PhotoTransferReceiptJournal.Entry) async -> PhotoTransferOutputCheck {
        guard entry.state == .committed, entry.outputProofs != nil else { return .unverifiable }
        let states = await currentStates(identifiers: entry.outputIdentifiers)
        return evaluate(outputIdentifiers: entry.outputIdentifiers, saved: entry.outputProofs, states: states)
    }

    /// 저장 직후 증명. 필요한 자원 종류가 하나라도 빠졌거나 읽지 못하면 nil(증명 없음 → 확인 불가로 남는다).
    static func captureProofs(
        identifiers: [String],
        requiredResourceTypes: [Set<Int>]
    ) async -> [PhotoTransferOutputProof]? {
        guard identifiers.count == requiredResourceTypes.count else { return nil }
        let states = await currentStates(identifiers: identifiers)
        var proofs: [PhotoTransferOutputProof] = []
        for (identifier, required) in zip(identifiers, requiredResourceTypes) {
            guard case .present(let proof) = states[identifier] ?? .unreadable,
                  required.isSubset(of: Set(proof.parts.map(\.resourceType))) else { return nil }
            proofs.append(proof)
        }
        return proofs
    }

    static func currentStates(identifiers: [String]) async -> [String: PhotoTransferOutputState] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited, !identifiers.isEmpty else {
            return Dictionary(uniqueKeysWithValues: identifiers.map { ($0, PhotoTransferOutputState.unreadable) })
        }
        var found: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            .enumerateObjects { asset, _, _ in found[asset.localIdentifier] = asset }
        var result: [String: PhotoTransferOutputState] = [:]
        for identifier in identifiers {
            guard let asset = found[identifier] else {
                // 제한 허용에서는 "없음"을 단정할 수 없다.
                result[identifier] = status == .authorized ? .absent : .unreadable
                continue
            }
            if let proof = await proof(for: asset) {
                result[identifier] = .present(proof)
            } else {
                result[identifier] = .unreadable
            }
        }
        return result
    }

    private static func proof(for asset: PHAsset) async -> PhotoTransferOutputProof? {
        let kind: String
        if asset.mediaType == .video { kind = "video" }
        else if asset.mediaSubtypes.contains(.photoLive) { kind = "livePhoto" }
        else { kind = "photo" }
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { return nil }
        var parts: [PhotoTransferOutputProof.Part] = []
        for resource in resources {
            guard let part = await hashedPart(of: resource) else { return nil }
            parts.append(part)
        }
        parts.sort { $0.resourceType < $1.resourceType }
        return PhotoTransferOutputProof(identifier: asset.localIdentifier, kind: kind, parts: parts)
    }

    private final class HashBox: @unchecked Sendable {
        var hasher = SHA256()
        var length: UInt64 = 0
    }

    /// 자원 바이트를 도착하는 대로 해시한다(전체를 메모리에 올리지 않는다). 네트워크(iCloud) 다운로드는 허용하지 않는다.
    private static func hashedPart(of resource: PHAssetResource) async -> PhotoTransferOutputProof.Part? {
        let box = HashBox()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let failed: Bool = await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                box.hasher.update(data: data)
                box.length += UInt64(data.count)
            } completionHandler: { error in
                continuation.resume(returning: error != nil)
            }
        }
        if failed { return nil }
        let digest = box.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .init(resourceType: resource.type.rawValue, sha256: digest, byteLength: box.length)
    }
}
