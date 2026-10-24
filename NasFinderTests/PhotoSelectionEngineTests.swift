import XCTest
@testable import NasFinder

/// 사진 선별 추천·선택 정책. 합성 수치만 쓰며 실제 사진이나 모델 정확도를 주장하지 않는다.
final class PhotoSelectionEngineTests: XCTestCase {
    private func candidate(_ index: Int, sharpness: Double = 0.6, exposure: Double = 0.8,
                           pixels: Int = 12_000_000, aesthetics: Double? = nil) -> PhotoSelectionCandidate {
        PhotoSelectionCandidate(index: index, sharpness: sharpness, exposure: exposure, pixelCount: pixels, aesthetics: aesthetics)
    }

    func testRecommendationCountsSceneGroupsNotAllPhotos() throws {
        // 0·1·2는 서로 비슷한 한 장면, 3은 다른 장면, 4는 또 다른 장면.
        let candidates = [candidate(0, sharpness: 0.9), candidate(1, sharpness: 0.5), candidate(2, sharpness: 0.4),
                          candidate(3), candidate(4)]
        let pairs = [PhotoSelectionPair(first: 0, second: 1, distance: 0.1),
                     PhotoSelectionPair(first: 0, second: 2, distance: 0.2),
                     PhotoSelectionPair(first: 1, second: 2, distance: 0.2)]
        let recommendation = try XCTUnwrap(PhotoSelectionEngine.recommend(candidates: candidates, pairs: pairs))
        XCTAssertEqual(recommendation.eligibleCount, 5)
        XCTAssertEqual(recommendation.groupCount, 3)
        XCTAssertEqual(recommendation.recommendedCount, 3)
        XCTAssertTrue(recommendation.groups.contains { $0.representative == 0 && Set($0.members) == [0, 1, 2] })
    }

    func testNoPairsMeansEveryPhotoIsItsOwnScene() throws {
        let candidates = (0..<8).map { candidate($0) }
        let recommendation = try XCTUnwrap(PhotoSelectionEngine.recommend(candidates: candidates, pairs: []))
        XCTAssertEqual(recommendation.recommendedCount, 8)
    }

    func testSeverelyBlurredRepresentativeIsLeftOutOfRecommendation() throws {
        let candidates = [candidate(0), candidate(1), candidate(2, sharpness: 0.0), candidate(3)]
        let recommendation = try XCTUnwrap(PhotoSelectionEngine.recommend(candidates: candidates, pairs: []))
        XCTAssertEqual(recommendation.groupCount, 4)
        XCTAssertEqual(recommendation.lowQualityCount, 1)
        XCTAssertEqual(recommendation.recommendedCount, 3)
    }

    func testAllLowQualityRecommendsTheBestSingleNotZeroNotAll() throws {
        let candidates = (0..<4).map { candidate($0, sharpness: 0.0, exposure: 0.0) }
        let recommendation = try XCTUnwrap(PhotoSelectionEngine.recommend(candidates: candidates, pairs: []))
        XCTAssertEqual(recommendation.recommendedCount, 1)
    }

    func testTukeyLowerFenceMarksOutlierRepresentative() throws {
        // 대표 점수 분포에서 크게 벗어난 하나만 낮은 품질로 본다. 고정 비율이 아니라 분포 기준이다.
        var candidates = (0..<7).map { candidate($0, sharpness: 0.8) }
        candidates.append(candidate(7, sharpness: 0.05, exposure: 0.15, pixels: 90_000))
        let recommendation = try XCTUnwrap(PhotoSelectionEngine.recommend(candidates: candidates, pairs: []))
        XCTAssertEqual(recommendation.lowQualityCount, 1)
        XCTAssertEqual(recommendation.recommendedCount, 7)
    }

    func testRecommendationReturnsNilWhenNothingIsEligible() {
        XCTAssertNil(PhotoSelectionEngine.recommend(candidates: [], pairs: []))
        let invalid = [PhotoSelectionCandidate(index: 0, sharpness: 2, exposure: 0.5, pixelCount: 10, aesthetics: nil)]
        XCTAssertNil(PhotoSelectionEngine.recommend(candidates: invalid, pairs: []))
    }

    func testExplicitCountIsNeverReplacedByTheRecommendation() throws {
        let candidates = (0..<10).map { candidate($0) }
        let recommended = try XCTUnwrap(PhotoSelectionEngine.recommend(candidates: candidates, pairs: [])).recommendedCount
        XCTAssertEqual(recommended, 10)
        for count in [1, 3, 10] {
            let outcome = try PhotoSelectionEngine.select(candidates: candidates, pairs: [], count: count).get()
            XCTAssertEqual(outcome.selectedIndices.count, count, "사용자가 정한 N=\(count)이 그대로 유지돼야 합니다.")
        }
    }

    func testCountAboveEligibleIsAnErrorNotASilentShrink() {
        let candidates = (0..<5).map { candidate($0) }
        XCTAssertEqual(
            PhotoSelectionEngine.select(candidates: candidates, pairs: [], count: 6),
            .failure(.countExceedsEligible(requested: 6, eligible: 5)))
        XCTAssertEqual(PhotoSelectionEngine.select(candidates: candidates, pairs: [], count: 0), .failure(.countBelowOne))
        XCTAssertEqual(PhotoSelectionEngine.select(candidates: [], pairs: [], count: 1), .failure(.noEligibleCandidate))
    }

    func testInvalidCandidatesAreNotCountedTowardTheMaximum() {
        let candidates = (0..<3).map { candidate($0) } + [PhotoSelectionCandidate(index: 9, sharpness: .nan, exposure: 0.5, pixelCount: 1, aesthetics: nil)]
        XCTAssertEqual(PhotoSelectionEngine.select(candidates: candidates, pairs: [], count: 4),
                       .failure(.countExceedsEligible(requested: 4, eligible: 3)))
    }

    func testNoArtificialUpperCapAtTwoHundred() throws {
        let candidates = (0..<350).map { candidate($0) }
        let outcome = try PhotoSelectionEngine.select(candidates: candidates, pairs: [], count: 350).get()
        XCTAssertEqual(outcome.selectedIndices.count, 350)
        XCTAssertEqual(try PhotoSelectionEngine.select(candidates: candidates, pairs: [], count: 1).get().selectedIndices.count, 1)
    }

    func testSelectionCoversEveryGroupBeforeTakingExtrasFromSimilarPhotos() throws {
        let candidates = [candidate(0, sharpness: 0.9), candidate(1, sharpness: 0.8), candidate(2, sharpness: 0.7), candidate(3)]
        let pairs = [PhotoSelectionPair(first: 0, second: 1, distance: 0.1),
                     PhotoSelectionPair(first: 0, second: 2, distance: 0.1),
                     PhotoSelectionPair(first: 1, second: 2, distance: 0.1)]
        let two = try PhotoSelectionEngine.select(candidates: candidates, pairs: pairs, count: 2).get()
        XCTAssertEqual(two.selectedIndices, [0, 3])
        XCTAssertEqual(two.extraFromSimilarCount, 0)
        let three = try PhotoSelectionEngine.select(candidates: candidates, pairs: pairs, count: 3).get()
        XCTAssertEqual(three.extraFromSimilarCount, 1)
        XCTAssertFalse(three.warnings.isEmpty, "묶음 수보다 많이 고르면 이유가 경고로 남아야 합니다.")
    }

    func testQuantileUsesLinearInterpolation() {
        XCTAssertEqual(PhotoSelectionEngine.quantile([1, 2, 3, 4], 0.25), 1.75, accuracy: 1e-9)
        XCTAssertEqual(PhotoSelectionEngine.quantile([1, 2, 3, 4], 0.75), 3.25, accuracy: 1e-9)
        XCTAssertNil(PhotoSelectionEngine.lowerFence(of: [1, 2, 3]), "대표가 4개 미만이면 분포 하한을 쓰지 않습니다.")
    }

    func testSelectionPrioritizesNormalRepresentativesOverLowQuality() throws {
        // 4개의 일반 그룹(숲/도시/해변/실내)과 1개의 낮은 품질 그룹(흐림)
        // 추천은 낮은 품질 그룹을 제외하고 4장을 추천한다.
        // N=4 선택 시 낮은 품질 대표를 건너뛰고 4개의 일반 그룹 대표를 선택해야 한다.
        let candidates = [
            candidate(0, sharpness: 0.7, exposure: 0.7), // 숲 (정상)
            candidate(1, sharpness: 0.8, exposure: 0.8), // 도시 (정상)
            candidate(2, sharpness: 0.85, exposure: 0.75), // 해변 (정상)
            candidate(3, sharpness: 0.75, exposure: 0.7), // 실내 (정상)
            candidate(4, sharpness: 0.0, exposure: 0.8), // 흐린 사진 (낮은 품질)
        ]
        let rec = try XCTUnwrap(PhotoSelectionEngine.recommend(candidates: candidates, pairs: []))
        XCTAssertEqual(rec.groupCount, 5)
        XCTAssertEqual(rec.lowQualityCount, 1)
        XCTAssertEqual(rec.recommendedCount, 4)

        let outcome = try PhotoSelectionEngine.select(candidates: candidates, pairs: [], count: 4).get()
        XCTAssertEqual(outcome.selectedIndices, [0, 1, 2, 3])
        XCTAssertFalse(outcome.selectedIndices.contains(4), "낮은 품질 대표는 일반 품질 대표 4개가 우선 선택되어 제외되어야 합니다.")
        XCTAssertEqual(outcome.extraFromSimilarCount, 0)
    }

    func testSelectionExplicit1PicksBestNormalRepresentativeWhenAvailable() throws {
        // 일반 품질 후보 중 점수가 더 높은 것을 우선 선택한다.
        let candidates = [
            candidate(0, sharpness: 0.5, exposure: 0.6), // 일반 (낮은 점수)
            candidate(1, sharpness: 0.95, exposure: 0.9), // 일반 (높은 점수 - 최고)
            candidate(2, sharpness: 0.0, exposure: 0.9), // 낮은 품질
        ]
        let outcome = try PhotoSelectionEngine.select(candidates: candidates, pairs: [], count: 1).get()
        XCTAssertEqual(outcome.selectedIndices, [1], "N=1일 때 사용 가능한 최고 품질의 일반 대표를 선택해야 합니다.")
    }

    func testSelectionExplicitAll8ReturnsAllCandidates() throws {
        let candidates = (0..<8).map { i in
            candidate(i, sharpness: i == 7 ? 0.0 : 0.6, exposure: 0.7)
        }
        let outcome = try PhotoSelectionEngine.select(candidates: candidates, pairs: [], count: 8).get()
        XCTAssertEqual(outcome.selectedIndices, Array(0..<8))
        XCTAssertEqual(outcome.selectedIndices.count, 8)
    }

    func testAllLowQualityHonorsExplicitCountWhileRecommendationIsOne() throws {
        // 모든 후보가 낮은 품질인 경우 추천은 가장 나은 1장이지만, 명시적 N은 그대로 유지된다.
        let candidates = (0..<4).map { candidate($0, sharpness: 0.0, exposure: 0.05) }
        let rec = try XCTUnwrap(PhotoSelectionEngine.recommend(candidates: candidates, pairs: []))
        XCTAssertEqual(rec.recommendedCount, 1)

        let one = try PhotoSelectionEngine.select(candidates: candidates, pairs: [], count: 1).get()
        XCTAssertEqual(one.selectedIndices.count, 1)

        let three = try PhotoSelectionEngine.select(candidates: candidates, pairs: [], count: 3).get()
        XCTAssertEqual(three.selectedIndices.count, 3, "모든 그룹이 낮은 품질이어도 사용자가 요청한 N=3은 유지되어야 합니다.")

        let four = try PhotoSelectionEngine.select(candidates: candidates, pairs: [], count: 4).get()
        XCTAssertEqual(four.selectedIndices.count, 4)
    }

    func testExactCountPreservedAcrossRangeWithoutOverwriting() throws {
        let candidates = [
            candidate(0, sharpness: 0.8), candidate(1, sharpness: 0.7),
            candidate(2, sharpness: 0.0), candidate(3, sharpness: 0.6),
            candidate(4, sharpness: 0.85), candidate(5, sharpness: 0.5)
        ]
        for n in 1...candidates.count {
            let outcome = try PhotoSelectionEngine.select(candidates: candidates, pairs: [], count: n).get()
            XCTAssertEqual(outcome.selectedIndices.count, n, "요청한 N=\(n)이 정확히 보존되어야 합니다.")
        }
    }

    func testSelectedIndicesPreserveOriginalInputOrder() throws {
        // 품질 순위와 원본 입력 순서(index)가 다를 때 출력은 원본 순서(오름차순)로 정렬되어야 한다.
        let candidates = [
            candidate(0, sharpness: 0.4),
            candidate(1, sharpness: 0.95), // 최고 품질
            candidate(2, sharpness: 0.3),
            candidate(3, sharpness: 0.90), // 두 번째 품질
        ]
        let outcome = try PhotoSelectionEngine.select(candidates: candidates, pairs: [], count: 2).get()
        XCTAssertEqual(outcome.selectedIndices, [1, 3], "선택된 후보 1과 3이 입력 순서대로 정렬되어야 합니다.")
    }

    func testZeroEligibleCandidatesIsExplicitFailureNotConfusedWithLowQuality() {
        // 분석 실패(유효하지 않은 수치)로 적격 후보가 0인 경우 명시적 실패
        let invalid = [PhotoSelectionCandidate(index: 0, sharpness: .nan, exposure: 0.5, pixelCount: 1, aesthetics: nil)]
        XCTAssertEqual(PhotoSelectionEngine.select(candidates: invalid, pairs: [], count: 1), .failure(.noEligibleCandidate))

        // 낮은 품질의 사진은 적격 후보이며 실패로 간주되지 않는다.
        let lowQuality = [PhotoSelectionCandidate(index: 0, sharpness: 0.0, exposure: 0.05, pixelCount: 1000, aesthetics: nil)]
        let result = PhotoSelectionEngine.select(candidates: lowQuality, pairs: [], count: 1)
        guard case let .success(outcome) = result else {
            XCTFail("낮은 품질 사진은 분석 실패가 아닌 적격 후보여야 합니다.")
            return
        }
        XCTAssertEqual(outcome.selectedIndices, [0])
    }
}
