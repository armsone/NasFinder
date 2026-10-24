import Foundation
import HanAI

/// 사진 선별 정책 상수. 값의 근거와 상태는 `shared-contract/recommendation-policy.md`와 같다.
/// 모든 기준은 아직 사진형 자료로 보정되지 않은 설계 가정이다. 개발 상태는 이 주석과 정책 문서에만 두고 제품 화면에는 쓰지 않는다.
enum PhotoSelectionPolicy {
    /// 지문 근접도 c를 거리 d = 1 − c 로 바꿔 complete-link 그룹에 쓰는 문턱. (설계 가정)
    /// 0.60이 "평균 60% 비슷함"이나 사람이 느끼는 같은 장면 경계와 같다는 근거는 없다. 보정 전에는 사실로 취급하지 않는다.
    static let groupDistanceThreshold = 0.60
    /// 대표 사진이 이보다 흐리거나 어두우면/밝으면 추천 개수에서 뺀다. (설계 가정)
    static let severeSharpnessFloor = 0.02
    static let severeExposureFloor = 0.10
    /// 대표가 이 개수 이상일 때만 품질 분포(Tukey 하한)를 쓴다.
    static let distributionMinimumGroups = 4
    static let tukeyMultiplier = 1.5
}

/// 분석을 마친 사진 하나의 정규화된 수치. `aesthetics`는 Vision 원값 (raw+1)/2 로 0...1 이어야 한다.
struct PhotoSelectionCandidate: Equatable, Sendable {
    let index: Int
    let sharpness: Double
    let exposure: Double
    let pixelCount: Int
    let aesthetics: Double?
}

/// 두 사진이 "비슷한 장면"일 때만 존재하는 거리(0...1). 쌍이 없으면 비슷하지 않다는 뜻이다.
struct PhotoSelectionPair: Equatable, Sendable {
    let first: Int
    let second: Int
    let distance: Double
}

struct PhotoSelectionGroup: Equatable, Sendable {
    let representative: Int
    let members: [Int]
    let isLowQuality: Bool
}

struct PhotoSelectionRecommendation: Equatable, Sendable {
    let eligibleCount: Int
    let groups: [PhotoSelectionGroup]
    let scoreByIndex: [Int: Double]
    /// HanAI가 값이 올바르지 않다고 제외한 후보와 사유.
    let rejectedByIndex: [Int: String]
    let usesAesthetics: Bool
    let recommendedCount: Int

    var groupCount: Int { groups.count }
    var lowQualityCount: Int { groups.filter(\.isLowQuality).count }

    /// 사용자에게 보이는 관측값 이유. 내부 지표 이름이나 개발 메모는 넣지 않는다.
    var reasonLines: [String] {
        var lines = ["분석에 성공한 사진 \(eligibleCount)장은 비슷한 장면 \(groupCount)묶음으로 나뉩니다."]
        if lowQualityCount == groupCount {
            lines.append("모든 묶음의 대표가 선명도·밝기가 크게 부족해 가장 나은 1장만 추천합니다.")
        } else if lowQualityCount > 0 {
            lines.append("묶음 대표 중 선명도·밝기가 크게 부족한 \(lowQualityCount)장은 추천에서 뺐습니다.")
        }
        return lines
    }
}

enum PhotoSelectionError: Error, Equatable {
    case noEligibleCandidate
    case countBelowOne
    /// 지정한 N이 적격 사진 수보다 많다. 조용히 줄이지 않고 사용자에게 변경을 요구한다.
    case countExceedsEligible(requested: Int, eligible: Int)

    var message: String {
        switch self {
        case .noEligibleCandidate: "분석에 성공한 사진이 없어 선별할 수 없습니다. 실패한 항목을 다시 시도해 주세요."
        case .countBelowOne: "선별 개수는 1장 이상이어야 합니다."
        case let .countExceedsEligible(requested, eligible):
            "선별 개수 \(requested)장이 분석에 성공한 \(eligible)장보다 많습니다. 개수를 직접 바꿔 주세요."
        }
    }
}

enum PhotoSelectionRole: Equatable, Sendable {
    case groupRepresentative
    /// 같은 장면 묶음에서 대표 외에 추가로 고른 사진.
    case extraFromSimilarGroup
}

struct PhotoSelectionOutcome: Equatable, Sendable {
    /// 입력 순서(오름차순 index)로 정렬된 선택 결과.
    let selectedIndices: [Int]
    let roleByIndex: [Int: PhotoSelectionRole]
    let extraFromSimilarCount: Int
    let warnings: [String]
}

enum PhotoSelectionEngine {
    /// 품질(HanAI 점수 분포)과 다양성(장면 묶음)으로 추천 개수를 계산한다. 적격 후보가 없으면 nil.
    static func recommend(
        candidates: [PhotoSelectionCandidate],
        pairs: [PhotoSelectionPair]
    ) -> PhotoSelectionRecommendation? {
        let result = diversity(candidates: candidates, pairs: pairs, count: candidates.count)
        let eligible = Set(result.scoreByIndex.keys)
        guard !eligible.isEmpty else { return nil }
        let groups = evaluateGroups(candidates: candidates, diversityResult: result)
        let usable = groups.filter { !$0.isLowQuality }.count
        // 모두 낮으면 0장이나 전체가 아니라 가장 나은 1장.
        let recommended = max(1, usable)
        let allHaveAesthetics = candidates.filter { eligible.contains($0.index) }.allSatisfy { $0.aesthetics != nil }
        return PhotoSelectionRecommendation(
            eligibleCount: eligible.count, groups: groups, scoreByIndex: result.scoreByIndex,
            rejectedByIndex: result.rejectionReasonsByIndex.mapValues(rejectionText),
            usesAesthetics: allHaveAesthetics, recommendedCount: recommended)
    }

    /// 사용자가 정한 N장을 그대로 고른다. N은 절대 추천값으로 덮어쓰거나 조용히 줄이지 않는다.
    static func select(
        candidates: [PhotoSelectionCandidate],
        pairs: [PhotoSelectionPair],
        count: Int
    ) -> Result<PhotoSelectionOutcome, PhotoSelectionError> {
        guard count >= 1 else { return .failure(.countBelowOne) }
        let probe = diversity(candidates: candidates, pairs: pairs, count: candidates.count)
        let eligibleCount = probe.scoreByIndex.count
        guard eligibleCount > 0 else { return .failure(.noEligibleCandidate) }
        guard count <= eligibleCount else {
            return .failure(.countExceedsEligible(requested: count, eligible: eligibleCount))
        }

        let groups = evaluateGroups(candidates: candidates, diversityResult: probe)
        let normalGroups = groups.filter { !$0.isLowQuality }
        let lowGroups = groups.filter(\.isLowQuality)

        let sortedNormalReps = normalGroups
            .map(\.representative)
            .sorted {
                let s1 = probe.scoreByIndex[$0] ?? 0
                let s2 = probe.scoreByIndex[$1] ?? 0
                if s1 != s2 { return s1 > s2 }
                return $0 < $1
            }

        let sortedLowReps = lowGroups
            .map(\.representative)
            .sorted {
                let s1 = probe.scoreByIndex[$0] ?? 0
                let s2 = probe.scoreByIndex[$1] ?? 0
                if s1 != s2 { return s1 > s2 }
                return $0 < $1
            }

        var selected: [Int] = []
        var roles: [Int: PhotoSelectionRole] = [:]

        // 1계층: 일반 품질 그룹 대표 우선 선택
        let normalToTake = min(count, sortedNormalReps.count)
        let chosenNormalReps = Array(sortedNormalReps.prefix(normalToTake))
        selected.append(contentsOf: chosenNormalReps)
        for rep in chosenNormalReps {
            roles[rep] = .groupRepresentative
        }

        // 2계층: N이 더 필요한 경우에만 낮은 품질 그룹 대표 선택
        var remainingNeeded = count - selected.count
        if remainingNeeded > 0 {
            let lowToTake = min(remainingNeeded, sortedLowReps.count)
            let chosenLowReps = Array(sortedLowReps.prefix(lowToTake))
            selected.append(contentsOf: chosenLowReps)
            for rep in chosenLowReps {
                roles[rep] = .groupRepresentative
            }
            remainingNeeded -= lowToTake
        }

        // 3계층: N이 더 필요한 경우(N > 그룹 수 G), 기존 기증자 품질·다양성 순서로 추가 구성원 채우기
        if remainingNeeded > 0 {
            let allReps = Set(groups.map(\.representative))
            let donorResult = diversity(candidates: candidates, pairs: pairs, count: count)
            var chosenExtras: [Int] = []
            for idx in donorResult.selectedIndices where !allReps.contains(idx) {
                if !chosenExtras.contains(idx) {
                    chosenExtras.append(idx)
                }
            }
            if chosenExtras.count < remainingNeeded {
                let existing = Set(selected).union(chosenExtras)
                let fallback = probe.scoreByIndex.keys
                    .filter { !existing.contains($0) }
                    .sorted {
                        let s1 = probe.scoreByIndex[$0] ?? 0
                        let s2 = probe.scoreByIndex[$1] ?? 0
                        if s1 != s2 { return s1 > s2 }
                        return $0 < $1
                    }
                chosenExtras.append(contentsOf: fallback.prefix(remainingNeeded - chosenExtras.count))
            }
            let extrasToTake = Array(chosenExtras.prefix(remainingNeeded))
            selected.append(contentsOf: extrasToTake)
            for extra in extrasToTake {
                roles[extra] = .extraFromSimilarGroup
            }
        }

        let extra = roles.values.filter { $0 == .extraFromSimilarGroup }.count
        var warnings: [String] = []
        if extra > 0 {
            warnings.append("장면 묶음 \(probe.groups.count)개보다 많이 골라 비슷한 사진 \(extra)장이 포함됩니다.")
        }
        return .success(PhotoSelectionOutcome(
            selectedIndices: selected.sorted(),
            roleByIndex: roles,
            extraFromSimilarCount: extra,
            warnings: warnings
        ))
    }

    private static func evaluateGroups(
        candidates: [PhotoSelectionCandidate],
        diversityResult: ImageDiversityResult
    ) -> [PhotoSelectionGroup] {
        let byIndex = Dictionary(candidates.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let representativeScores = diversityResult.groups.compactMap { diversityResult.scoreByIndex[$0.representativeIndex] }
        let fence = lowerFence(of: representativeScores)
        return diversityResult.groups.map { group -> PhotoSelectionGroup in
            let rep = group.representativeIndex
            let candidate = byIndex[rep]
            let score = diversityResult.scoreByIndex[rep] ?? 0
            let severe = (candidate?.sharpness ?? 1) < PhotoSelectionPolicy.severeSharpnessFloor
                || (candidate?.exposure ?? 1) < PhotoSelectionPolicy.severeExposureFloor
            let belowFence = fence.map { score < $0 } ?? false
            return PhotoSelectionGroup(representative: rep, members: group.memberIndices, isLowQuality: severe || belowFence)
        }
    }

    private static func diversity(
        candidates: [PhotoSelectionCandidate],
        pairs: [PhotoSelectionPair],
        count: Int
    ) -> ImageDiversityResult {
        ImageDiversitySelector.selectDiverse(
            candidates: candidates.map {
                ImageQualityCandidate(
                    index: $0.index, sharpness: $0.sharpness, exposureScore: $0.exposure,
                    pixelCount: $0.pixelCount, aestheticsScore: $0.aesthetics)
            },
            distances: pairs.map { ImagePairDistance(firstIndex: $0.first, secondIndex: $0.second, distance: $0.distance) },
            threshold: PhotoSelectionPolicy.groupDistanceThreshold,
            n: count)
    }

    /// 대표 점수 분포의 Tukey 하한 Q1 − 1.5·IQR. 대표가 충분하지 않으면 nil(절대 하한만 쓴다).
    static func lowerFence(of scores: [Double]) -> Double? {
        guard scores.count >= PhotoSelectionPolicy.distributionMinimumGroups else { return nil }
        let sorted = scores.sorted()
        let q1 = quantile(sorted, 0.25)
        let q3 = quantile(sorted, 0.75)
        return q1 - PhotoSelectionPolicy.tukeyMultiplier * (q3 - q1)
    }

    /// 선형 보간 분위수.
    static func quantile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    private static func rejectionText(_ reason: ImageDiversityRejectionReason) -> String {
        switch reason {
        case .duplicateCandidateId, .invalidIndex: "분석 번호가 올바르지 않습니다."
        case .nonFiniteOrOutOfRangeSharpness: "선명도 값이 올바르지 않습니다."
        case .nonFiniteOrOutOfRangeExposure: "노출 값이 올바르지 않습니다."
        case .nonPositivePixelCount: "해상도를 확인하지 못했습니다."
        case .nonFiniteOrOutOfRangeAesthetics: "미적 점수 값이 올바르지 않습니다."
        }
    }
}
