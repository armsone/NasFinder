import XCTest
import HanAIApple
@testable import NasFinder

/// 사진 선별 추천·선택 정책. 합성 수치만 쓰며 실제 사진이나 모델 정확도를 주장하지 않는다.
final class PhotoSelectionEngineTests: XCTestCase {
    func testTrailerPhotoDurationWeights() {
        func measurement(_ score: Double, fingerprint: [UInt8] = []) -> VideoTrailerPhotoQuality.Measurement {
            .init(qualityScore: score, fingerprint: fingerprint, aspectRatio: 1,
                  sharpnessScore: score, exposureScore: 0.5)
        }
        let ordinary = VideoTrailerPhotoQuality.durationRatios(for: [
            (id: 0, measurement: measurement(1)),
            (id: 1, measurement: measurement(0.3)),
            (id: 2, measurement: measurement(0.1)),
            (id: 3, measurement: nil)
        ])
        XCTAssertEqual(ordinary[0] ?? 0, 1.25, accuracy: 0.00001)
        XCTAssertEqual(ordinary[1] ?? 0, 0.525, accuracy: 0.00001)
        XCTAssertEqual(ordinary[2] ?? 0, 0.10, accuracy: 0.00001)
        XCTAssertEqual(ordinary[3] ?? 0, 0.55, accuracy: 0.00001)

        let fingerprint = [UInt8](repeating: 100, count: 256)
        let duplicates = VideoTrailerPhotoQuality.durationRatios(for: [
            (id: 0, measurement: measurement(1, fingerprint: fingerprint)),
            (id: 1, measurement: measurement(0.1, fingerprint: fingerprint))
        ])
        XCTAssertEqual(duplicates[1] ?? 0, 0.01, accuracy: 0.00001)
    }

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

    func testManualHelpersBoundsMigrationAndRedistribution() {
        let analysis = AudioAnalysisResult(
            waveform: [], peakTime: 0, peakTimes: [],
            audioAvailability: .unknown, highlightSource: .fallback
        )
        let dummyURL = URL(fileURLWithPath: "/dummy")

        // mixed legacy photos .75 / .35 / .05 and video start 1 duration 8
        var sources = [
            VideoTrailerSource(
                id: 1, name: "photo1", url: dummyURL,
                plan: VideoTrailerPlan(analysis: analysis, duration: 4.0),
                isImage: true, imageDurationRatio: 0.75, imageDurationPolicyVersion: 1
            ),
            VideoTrailerSource(
                id: 2, name: "photo2", url: dummyURL,
                plan: VideoTrailerPlan(analysis: analysis, duration: 4.0),
                isImage: true, imageDurationRatio: 0.35, imageDurationPolicyVersion: 1
            ),
            VideoTrailerSource(
                id: 3, name: "photo3", url: dummyURL,
                plan: VideoTrailerPlan(analysis: analysis, duration: 4.0),
                isImage: true, imageDurationRatio: 0.05, imageDurationPolicyVersion: 1
            ),
            VideoTrailerSource(
                id: 4, name: "video", url: dummyURL,
                plan: VideoTrailerPlan(analysis: analysis, duration: 8.0),
                isImage: false, imageDurationRatio: 0.55, imageDurationPolicyVersion: 2
            ),
        ]

        var scenes = [
            TrailerEditScene(id: 101, sourceID: 1, start: 0, length: 1.0),
            TrailerEditScene(id: 102, sourceID: 2, start: 0, length: 1.0),
            TrailerEditScene(id: 103, sourceID: 3, start: 0, length: 1.0),
            TrailerEditScene(id: 104, sourceID: 4, start: 1.0, length: 2.0, muted: true, fitsFrame: true, volume: 0.7, offsetX: 0.2, offsetY: -0.3),
            TrailerEditScene(id: 105, sourceID: 4, start: 5.0, length: 2.0, excluded: true),
        ]

        // clip 2.5 => photo 2.375 / .25 / 1frame-or-weighted and video 2.5
        TrailerSceneEditor.applyExplicitClipLength(clipLength: 2.5, scenes: &scenes, sources: &sources)

        XCTAssertEqual(scenes[0].length, 2.375, accuracy: 0.0001)
        XCTAssertEqual(scenes[1].length, 0.25, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(scenes[2].length, 1.0 / 30.0)
        XCTAssertEqual(scenes[2].length, 2.5 * VideoTrailerPhotoQuality.migrateV1ToV2Ratio(0.05), accuracy: 0.0001)
        XCTAssertEqual(scenes[3].length, 2.5, accuracy: 0.0001)
        XCTAssertEqual(scenes[3].start, 1.0, accuracy: 0.0001)

        // ratio/version migrate once
        XCTAssertEqual(sources[0].imageDurationPolicyVersion, 2)
        XCTAssertEqual(sources[1].imageDurationPolicyVersion, 2)
        XCTAssertEqual(sources[2].imageDurationPolicyVersion, 2)
        XCTAssertEqual(sources[0].imageDurationRatio, 0.95, accuracy: 0.0001)
        XCTAssertEqual(sources[1].imageDurationRatio, 0.10, accuracy: 0.0001)

        // applying again 3 => new ratio not migrated again
        TrailerSceneEditor.applyExplicitClipLength(clipLength: 3.0, scenes: &scenes, sources: &sources)
        XCTAssertEqual(sources[0].imageDurationRatio, 0.95, accuracy: 0.0001)
        XCTAssertEqual(sources[1].imageDurationRatio, 0.10, accuracy: 0.0001)
        XCTAssertEqual(scenes[0].length, 3.0 * 0.95, accuracy: 0.0001)
        XCTAssertEqual(scenes[1].length, 3.0 * 0.10, accuracy: 0.0001)
        XCTAssertEqual(scenes[3].length, 3.0, accuracy: 0.0001)

        // total redistribution respects bounds and IDs/order/start/audio/excluded
        let bounds = TrailerSceneEditor.manualTotalBounds(scenes: scenes, sources: sources)
        XCTAssertEqual(bounds.minimum, 0.1 + 0.2, accuracy: 0.0001)
        XCTAssertEqual(bounds.maximum, 90.0 + 7.0, accuracy: 0.0001)

        let target = 15.0
        TrailerSceneEditor.redistributeManualTotal(scenes: &scenes, sources: sources, targetTotal: target)
        let actualSum = scenes.filter { !$0.excluded }.reduce(0.0) { $0 + $1.length }
        XCTAssertEqual(actualSum, target, accuracy: 0.001)

        // Verify bounds respected for each included scene
        XCTAssertGreaterThanOrEqual(scenes[0].length, 1.0 / 30.0)
        XCTAssertLessThanOrEqual(scenes[0].length, 30.0)
        XCTAssertGreaterThanOrEqual(scenes[1].length, 1.0 / 30.0)
        XCTAssertLessThanOrEqual(scenes[1].length, 30.0)
        XCTAssertGreaterThanOrEqual(scenes[2].length, 1.0 / 30.0)
        XCTAssertLessThanOrEqual(scenes[2].length, 30.0)
        XCTAssertGreaterThanOrEqual(scenes[3].length, 0.2)
        XCTAssertLessThanOrEqual(scenes[3].length, 7.0)

        // Verify IDs, order, start, audio, crop, excluded preserved
        XCTAssertEqual(scenes.map(\.id), [101, 102, 103, 104, 105])
        XCTAssertEqual(scenes.map(\.sourceID), [1, 2, 3, 4, 4])
        XCTAssertEqual(scenes[3].start, 1.0, accuracy: 0.0001)
        XCTAssertTrue(scenes[3].muted)
        XCTAssertTrue(scenes[3].fitsFrame)
        XCTAssertEqual(scenes[3].volume, 0.7, accuracy: 0.0001)
        XCTAssertEqual(scenes[3].offsetX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(scenes[3].offsetY, -0.3, accuracy: 0.0001)
        XCTAssertTrue(scenes[4].excluded)
        XCTAssertEqual(scenes[4].length, 2.0, accuracy: 0.0001)
        XCTAssertEqual(scenes[4].start, 5.0, accuracy: 0.0001)

        // staged copies with old legacy ratios/policy and refreshed file URLs
        let refreshedBaseURL = URL(fileURLWithPath: "/tmp/staged")
        let stagedSources = [
            VideoTrailerSource(
                id: 1, name: "photo1", url: refreshedBaseURL.appendingPathComponent("p1.jpg"),
                plan: VideoTrailerPlan(analysis: analysis, duration: 4.0),
                isImage: true, imageDurationRatio: 0.75, imageDurationPolicyVersion: 1
            ),
            VideoTrailerSource(
                id: 2, name: "photo2", url: refreshedBaseURL.appendingPathComponent("p2.jpg"),
                plan: VideoTrailerPlan(analysis: analysis, duration: 4.0),
                isImage: true, imageDurationRatio: 0.35, imageDurationPolicyVersion: 1
            ),
            VideoTrailerSource(
                id: 3, name: "photo3", url: refreshedBaseURL.appendingPathComponent("p3.jpg"),
                plan: VideoTrailerPlan(analysis: analysis, duration: 4.0),
                isImage: true, imageDurationRatio: 0.05, imageDurationPolicyVersion: 1
            ),
            VideoTrailerSource(
                id: 4, name: "video", url: refreshedBaseURL.appendingPathComponent("v4.mp4"),
                plan: VideoTrailerPlan(analysis: analysis, duration: 8.0),
                isImage: false, imageDurationRatio: 0.55, imageDurationPolicyVersion: 2
            ),
            VideoTrailerSource(
                id: 5, name: "extra", url: refreshedBaseURL.appendingPathComponent("p5.jpg"),
                plan: VideoTrailerPlan(analysis: analysis, duration: 4.0),
                isImage: true, imageDurationRatio: 0.55, imageDurationPolicyVersion: 2
            ),
        ]

        // edited migrated draft: reordered [3, 1], omitted 2, 4, 5
        let migratedDraftSources = [sources[2], sources[0]]
        let reconciled = TrailerSceneEditor.reconcileSources(draftSources: migratedDraftSources, stagedSources: stagedSources)

        // retains new ratio and version
        XCTAssertEqual(reconciled.count, 2)
        XCTAssertEqual(reconciled[0].imageDurationPolicyVersion, 2)
        XCTAssertEqual(reconciled[0].imageDurationRatio, sources[2].imageDurationRatio, accuracy: 0.0001)
        XCTAssertEqual(reconciled[1].imageDurationPolicyVersion, 2)
        XCTAssertEqual(reconciled[1].imageDurationRatio, 0.95, accuracy: 0.0001)

        // staged URL refreshed
        XCTAssertEqual(reconciled[0].url, refreshedBaseURL.appendingPathComponent("p3.jpg"))
        XCTAssertEqual(reconciled[1].url, refreshedBaseURL.appendingPathComponent("p1.jpg"))

        // omitted IDs/order preserved
        XCTAssertEqual(reconciled.map(\.id), [3, 1])

        // undo snapshot restores legacy ratio and policy version without being overwritten by staged
        let undoDraftSources = [
            VideoTrailerSource(
                id: 1, name: "photo1", url: dummyURL,
                plan: VideoTrailerPlan(analysis: analysis, duration: 4.0),
                isImage: true, imageDurationRatio: 0.75, imageDurationPolicyVersion: 1
            )
        ]
        var freshStagedSources = stagedSources
        freshStagedSources[0].imageDurationRatio = 0.95
        freshStagedSources[0].imageDurationPolicyVersion = 2

        // baseline old .75 with unchanged draft .75 accepts freshly staged .95/policy2
        let freshAccepted = TrailerSceneEditor.reconcileSources(
            draftSources: undoDraftSources,
            stagedSources: freshStagedSources,
            timingBaseline: undoDraftSources
        )
        XCTAssertEqual(freshAccepted[0].imageDurationRatio, 0.95, accuracy: 0.0001)
        XCTAssertEqual(freshAccepted[0].imageDurationPolicyVersion, 2)

        // explicit draft .8 preserves .8 over fresh .95
        var editedDraftSources = undoDraftSources
        editedDraftSources[0].imageDurationRatio = 0.8
        let explicitPreserved = TrailerSceneEditor.reconcileSources(
            draftSources: editedDraftSources,
            stagedSources: freshStagedSources,
            timingBaseline: undoDraftSources
        )
        XCTAssertEqual(explicitPreserved[0].imageDurationRatio, 0.8, accuracy: 0.0001)

        // undo legacy .75/policy1 against staged .95/policy2 with no baseline restores legacy pair
        let restoredUndo = TrailerSceneEditor.reconcileSources(draftSources: undoDraftSources, stagedSources: freshStagedSources)
        XCTAssertEqual(restoredUndo.count, 1)
        XCTAssertEqual(restoredUndo[0].id, 1)
        XCTAssertEqual(restoredUndo[0].imageDurationPolicyVersion, 1)
        XCTAssertEqual(restoredUndo[0].imageDurationRatio, 0.75, accuracy: 0.0001)
        XCTAssertEqual(restoredUndo[0].url, refreshedBaseURL.appendingPathComponent("p1.jpg"))
    }
}
