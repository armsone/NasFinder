import AVFoundation
import CryptoKit
import UniformTypeIdentifiers
import UIKit
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

    /// 비트 맞춤: 영상 장면도 실제 원본 범위 안에서 비트에 닿고, 시작·순서·자막은 그대로이며, 음악 길이 맞춤은 끝을 정확히 채운다.
    func testBeatSyncMovesVideoAndPhotoScenesWithinSourceBoundsAndFillsMusicBudget() {
        let analysis = AudioAnalysisResult(waveform: [], peakTime: 0, peakTimes: [], audioAvailability: .unknown, highlightSource: .fallback)
        let dummyURL = URL(fileURLWithPath: "/dummy")
        let sources = [
            VideoTrailerSource(id: 1, name: "video", url: dummyURL, plan: VideoTrailerPlan(analysis: analysis, duration: 20.0), isImage: false),
            VideoTrailerSource(id: 2, name: "photo", url: dummyURL, plan: VideoTrailerPlan(analysis: analysis, duration: 4.0), isImage: true),
        ]
        let musicDuration = 12.0
        // 0.5초 간격이 아닌 불규칙한 비트(원래 컷 4.0/7.0/10.0과 모두 어긋남)
        let beats = [0.0, 1.3, 3.1, 4.4, 6.2, 7.5, 9.1, 10.6, 11.2]
        func makeScenes() -> [TrailerEditScene] {
            [TrailerEditScene(id: 11, sourceID: 1, start: 5.0, length: 4.0),
             TrailerEditScene(id: 12, sourceID: 2, start: 0, length: 3.0),
             TrailerEditScene(id: 13, sourceID: 1, start: 14.0, length: 3.0, muted: true),
             TrailerEditScene(id: 14, sourceID: 2, start: 0, length: 2.0)]
        }

        var scenes = makeScenes()
        let fit = TrailerSceneEditor.syncScenesToBeatOnsets(
            scenes: &scenes, sources: sources, beatOnsets: beats, musicDuration: musicDuration,
            policy: .fitMusic, maxBudget: musicDuration)
        XCTAssertEqual(scenes.reduce(0.0) { $0 + $1.length }, musicDuration, accuracy: 0.001, "마지막 장면이 남은 시간을 받아 음악 끝에 닿아야 합니다.")
        XCTAssertEqual(fit.fitResidual, 0, accuracy: 0.01)
        XCTAssertGreaterThan(fit.adjustedCount, 0)
        XCTAssertEqual(scenes.map(\.id), [11, 12, 13, 14])
        XCTAssertEqual(scenes.map(\.start), [5.0, 0, 14.0, 0])
        XCTAssertTrue(scenes[2].muted)
        XCTAssertLessThanOrEqual(scenes[2].length, 20.0 - 14.0 + 1e-9, "영상 장면은 원본 끝을 넘지 않아야 합니다.")
        // 마지막 장면 앞의 컷은 모두 비트 위에 있다.
        var cut = 0.0
        for scene in scenes.dropLast() {
            cut += scene.length
            XCTAssertTrue(beats.contains { abs($0 - cut) < 0.001 }, "컷 \(cut)은 비트가 아닙니다.")
        }

        // 음악 한 번: 예산 없이 비트에만 맞추며 영상 길이는 원본 범위 안.
        var single = makeScenes()
        TrailerSceneEditor.syncScenesToBeatOnsets(scenes: &single, sources: sources, beatOnsets: beats, musicDuration: musicDuration, policy: .single)
        XCTAssertEqual(single.map(\.start), [5.0, 0, 14.0, 0])
        XCTAssertLessThanOrEqual(single[2].length, 6.0 + 1e-9)

        // 제외 장면과 비트 없음은 건드리지 않는다.
        var untouched = makeScenes()
        untouched[1].excluded = true
        let none = TrailerSceneEditor.syncScenesToBeatOnsets(scenes: &untouched, sources: sources, beatOnsets: [], musicDuration: musicDuration, policy: .loopMusic)
        XCTAssertEqual(none.adjustedCount, 0)
        XCTAssertEqual(untouched.map(\.length), [4.0, 3.0, 3.0, 2.0])
    }

    // MARK: 동작 보호 / 검증 임팩트 / 음악 반복 / 추천 사본

    /// 파형: 0~1초 단위 20칸 중 칸 `index`가 가장 크고, 나머지는 `base`.
    private func spikeSource(id: Int, duration: Double = 20, spike: Int, base: Double = 0.1, spikeValue: Double = 1.0,
                             peakTimes: [Double], verified: [Double] = []) -> VideoTrailerSource {
        var wave = [Double](repeating: base, count: 20)
        wave[spike] = spikeValue
        let analysis = AudioAnalysisResult(waveform: wave, peakTime: peakTimes.first ?? 0, peakTimes: peakTimes,
                                           audioAvailability: .present, highlightSource: .audio, verifiedPeakTimes: verified)
        return VideoTrailerSource(id: id, name: "v\(id)", url: URL(fileURLWithPath: "/dummy"),
                                  plan: VideoTrailerPlan(analysis: analysis, duration: duration), isImage: false)
    }

    /// 검증된 타격은 55% 음량 컷에 걸리지 않고 큰 소리보다 먼저 쓰인다.
    func testVerifiedImpactOutranksLouderUnverifiedPeak() {
        // 큰 소리 피크(5.5s)와 조용하지만 검증된 타격(14.5s, 파형 0.3)
        var wave = [Double](repeating: 0.1, count: 20)
        wave[5] = 1.0
        wave[14] = 0.3
        func plan(_ verified: [Double]) -> VideoTrailerPlan {
            VideoTrailerPlan(analysis: AudioAnalysisResult(waveform: wave, peakTime: 5.5, peakTimes: [5.5, 14.5],
                audioAvailability: .present, highlightSource: .audio, verifiedPeakTimes: verified), duration: 20)
        }
        let unverified = plan([]).proposal(total: 4, clipLength: 4)
        XCTAssertEqual(unverified.count, 1)
        XCTAssertEqual(unverified[0].start, 3.5, accuracy: 0.01, "검증 정보가 없으면 가장 큰 소리가 기준입니다.")
        let verifiedStart = plan([14.5]).proposal(total: 4, clipLength: 4)
        XCTAssertEqual(verifiedStart.count, 1)
        XCTAssertEqual(verifiedStart[0].start, 12.5, accuracy: 0.01, "검증된 조용한 타격이 더 큰 소리보다 먼저 기준이 되어야 합니다.")
    }

    /// 동작 보호: 길이를 줄여도 보호 구간이 창 안에 남고, 보호 길이 아래로 줄지 않으며, 수동 트림(앵커 없음)은 그대로 줄어든다.
    func testProtectedActionSurvivesShrinkAndManualTrimIsUntouched() {
        let source = spikeSource(id: 1, spike: 10, peakTimes: [10.5])
        var protectedScene = TrailerEditScene(id: 1, sourceID: 1, start: 8.0, length: 4.0, actionStart: 8.0, actionEnd: 12.0)
        var manual = TrailerEditScene(id: 2, sourceID: 1, start: 8.0, length: 4.0)
        XCTAssertEqual(TrailerSceneEditor.sceneDurationBounds(scene: protectedScene, source: source).minimum, 4.0, accuracy: 1e-9)
        XCTAssertEqual(TrailerSceneEditor.sceneDurationBounds(scene: manual, source: source).minimum, 0.2, accuracy: 1e-9)
        var scenes = [protectedScene, manual]
        TrailerSceneEditor.redistributeManualTotal(scenes: &scenes, sources: [source], targetTotal: 3.0)
        protectedScene = scenes[0]; manual = scenes[1]
        XCTAssertEqual(protectedScene.length, 4.0, accuracy: 1e-6, "보호 구간은 잘리지 않습니다.")
        XCTAssertLessThan(manual.length, 4.0, "앵커 없는 수동 트림은 기존대로 줄어듭니다.")
        XCTAssertEqual(manual.start, 8.0, accuracy: 1e-6)
        // 더 긴 길이에서는 시작점이 보호 구간을 포함하도록 움직인다.
        XCTAssertEqual(TrailerSceneEditor.startKeepingAction(protectedScene, start: 9.0, length: 5.0, sourceDuration: 20), 8.0, accuracy: 1e-9)
        XCTAssertEqual(TrailerSceneEditor.startKeepingAction(protectedScene, start: 5.0, length: 5.0, sourceDuration: 20), 7.0, accuracy: 1e-9)
    }

    /// 음악 맞춤: 고른 반복 횟수 그대로이고, 보호 길이가 그 길이를 넘으면 직접 편집한 장면을 자르지 않고 덜 중요한 자동 장면을 피크 중심으로 좁히거나(자리가 있으면) 뺀다.
    func testMusicFitKeepsTheChosenCountAndReservesWholeScenes() {
        let sources = [spikeSource(id: 1, spike: 10, peakTimes: [10.5]), spikeSource(id: 2, spike: 3, peakTimes: [3.5])]
        func scenes() -> [TrailerEditScene] {
            var list = [TrailerEditScene(id: 1, sourceID: 1, start: 5.0, length: 6.0, actionStart: 5.0, actionEnd: 11.0),
                        TrailerEditScene(id: 2, sourceID: 2, start: 1.0, length: 6.0, actionStart: 1.0, actionEnd: 7.0)]
            // 자막은 사용자가 고친 것으로 기록해야 직접 편집 장면(빠지지 않음)이다.
            TrailerSceneEditor.update(2, in: &list) { $0.caption = TrailerCaption(text: "끝") }
            return list
        }
        var fits = scenes()
        let one = TrailerSceneEditor.fitScenesToMusic(scenes: &fits, sources: sources, musicDuration: 10, startCount: 1, cardsDuration: 0, maximumRepeats: 600)
        XCTAssertEqual(one.count, 1, "반복 횟수는 자동으로 늘지 않습니다.")
        XCTAssertTrue(one.fits)
        // 자막 장면(최소 6초)이 먼저 자리를 잡고 남는 4초에 순수 자동 장면이 빠지는 대신 실제 피크(10.5초)를 담도록 좁아져 둘 다 산다.
        XCTAssertEqual(one.excluded, 0)
        XCTAssertEqual(one.total, 10.0, accuracy: 1e-3)
        XCTAssertEqual(fits[1].length, 6.0, accuracy: 1e-6, "자막 장면의 동작 구간은 그대로입니다.")
        XCTAssertEqual(fits[0].length, 4.0, accuracy: 1e-3)
        XCTAssertLessThanOrEqual(fits[0].start, 10.5)
        XCTAssertGreaterThanOrEqual(fits[0].start + fits[0].length, 10.5)
        XCTAssertGreaterThanOrEqual(fits[0].start, 5.0 - 1e-9, "기존 동작 구간 안의 시각만 씁니다.")
        XCTAssertLessThanOrEqual(fits[0].start + fits[0].length, 11.0 + 1e-9)
        XCTAssertFalse(fits.contains { $0.excluded || $0.budgetExcluded })
        // 2회로 늘리면 뺀 장면이 자막 그대로 다시 들어간다.
        let two = TrailerSceneEditor.fitScenesToMusic(scenes: &fits, sources: sources, musicDuration: 10, startCount: 2, cardsDuration: 0, maximumRepeats: 600)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two.excluded, 0)
        XCTAssertEqual(two.total, 20.0, accuracy: 0.001)
        XCTAssertEqual(fits.map(\.id), [1, 2])
        XCTAssertEqual(fits[1].caption?.text, "끝")
        XCTAssertFalse(fits.contains { $0.excluded || $0.budgetExcluded })
        // 한 장면도 통째로 안 들어가도 실패하지 않는다: 자막 장면이 실제 피크(3.5초)를 담도록 요청한 4초로 좁아지고 자막·순서는 그대로이며,
        // 순수 자동 장면이 먼저 빠진다.
        var tiny = scenes()
        let none = TrailerSceneEditor.fitScenesToMusic(scenes: &tiny, sources: sources, musicDuration: 4, startCount: 1, cardsDuration: 0, maximumRepeats: 600)
        XCTAssertTrue(none.fits)
        XCTAssertEqual(none.total, 4.0, accuracy: 1e-3)
        XCTAssertEqual(none.excluded, 1)
        XCTAssertEqual(tiny.map(\.id), [1, 2])
        XCTAssertTrue(tiny[0].excluded && tiny[0].budgetExcluded, "순수 자동 장면이 먼저 빠집니다.")
        XCTAssertFalse(tiny[1].excluded || tiny[1].budgetExcluded, "자막 장면은 사라지지 않습니다.")
        XCTAssertEqual(tiny[1].caption?.text, "끝")
        XCTAssertEqual(tiny[1].length, 4.0, accuracy: 1e-3)
        XCTAssertLessThanOrEqual(tiny[1].start, 3.5, "좁힌 창이 실제 피크를 담습니다.")
        XCTAssertGreaterThanOrEqual(tiny[1].start + tiny[1].length, 3.5)
        XCTAssertGreaterThanOrEqual(tiny[1].start, 1.0 - 1e-9, "기존 동작 구간 안의 시각만 씁니다.")
        XCTAssertLessThanOrEqual(tiny[1].start + tiny[1].length, 7.0 + 1e-9)
        // 사용자가 직접 제외한 장면은 예산이 다시 넣지 않는다.
        var userExcluded = scenes()
        userExcluded[0].excluded = true
        TrailerSceneEditor.fitScenesToBudget(scenes: &userExcluded, sources: sources, bodyTarget: 30)
        XCTAssertTrue(userExcluded[0].excluded)
        XCTAssertFalse(userExcluded[0].budgetExcluded)
    }

    /// 새 추천 사본: 소스별 새 창을 순서대로 받고 자막·순서·제외·음량은 유지하며 앵커를 새 창으로 쓴다. 근거 없는 소스와 원본 입력은 그대로.
    func testRebuiltFromRecommendationMovesWindowsAndKeepsEdits() {
        let evidence = spikeSource(id: 1, spike: 15, peakTimes: [15.5])
        let analysis = AudioAnalysisResult(waveform: [], peakTime: 0, peakTimes: [], audioAvailability: .unknown, highlightSource: .fallback)
        let flat = VideoTrailerSource(id: 2, name: "flat", url: URL(fileURLWithPath: "/dummy"),
                                      plan: VideoTrailerPlan(analysis: analysis, duration: 20), isImage: false)
        let caption = TrailerCaption(text: "자막")
        let original = [TrailerEditScene(id: 7, sourceID: 1, start: 0, length: 4.0, volume: 0.4, caption: caption),
                        TrailerEditScene(id: 8, sourceID: 2, start: 0, length: 4.0)]
        let rebuilt = TrailerSceneEditor.rebuiltFromRecommendation(scenes: original, sources: [evidence, flat])
        XCTAssertEqual(rebuilt.map(\.id), [7, 8])
        // 피크 15.5의 보호 구간은 앞 lead~뒤 follow(클릭 없는 소리라 약한 근거 follow, 소스 끝 20초에서 잘림).
        // 장면 길이 4초보다 길면 창이 그 동작 전체(가운데 정렬)가 된다.
        let lead = VideoTrailerPlan.actionLeadSeconds
        let end = min(20, 15.5 + VideoTrailerPlan.weakActionFollowSeconds)
        let span = end - (15.5 - lead)
        XCTAssertEqual(rebuilt[0].start, 15.5 - lead - (max(4.0, span) - span) / 2, accuracy: 0.01, "start=0이던 장면이 피크 쪽으로 옮겨져야 합니다.")
        XCTAssertEqual(rebuilt[0].length, max(4.0, span), accuracy: 1e-9)
        XCTAssertEqual(rebuilt[0].actionStart ?? -1, 15.5 - lead, accuracy: 0.01)
        XCTAssertEqual(rebuilt[0].actionEnd ?? -1, end, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(rebuilt[0].start + rebuilt[0].length, rebuilt[0].actionEnd ?? .infinity, "창이 보호 동작 전체를 담아야 합니다.")
        XCTAssertEqual(rebuilt[0].volume, 0.4)
        XCTAssertEqual(rebuilt[0].caption, caption)
        XCTAssertEqual(rebuilt[1], original[1], "근거 없는 소스의 장면은 건드리지 않습니다.")
        XCTAssertEqual(original[0].start, 0, "입력 배열(원본)은 바뀌지 않습니다.")
    }

    /// 장면이 1개인 소스는 가장 이른 후보가 아니라 가장 강한 피크의 창을 받는다.
    func testRebuiltPicksStrongestWindowNotEarliest() {
        let source = spikeSource(id: 1, spike: 15, peakTimes: [15.5, 4.5])
        let rebuilt = TrailerSceneEditor.rebuiltFromRecommendation(scenes: [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 4)], sources: [source])
        XCTAssertGreaterThan(rebuilt[0].start, 10, "가장 강한 피크(15.5s) 쪽 창이어야 하고 4.5s 근처가 아닙니다.")
    }

    /// 앵커는 저장·복원에서 유지되고, 구버전(키 없음)과 잘못된 구간은 보호 없음으로 읽는다.
    func testActionAnchorsRoundTripAndLegacyDecode() throws {
        let scene = TrailerEditScene(id: 1, sourceID: 1, start: 3.0, length: 4.0, actionStart: 3.0, actionEnd: 7.0)
        let decoded = try JSONDecoder().decode(TrailerEditScene.self, from: try JSONEncoder().encode(scene))
        XCTAssertEqual(decoded, scene)
        let legacy = #"{"id":1,"sourceID":1,"start":3,"length":4}"#.data(using: .utf8)!
        let old = try JSONDecoder().decode(TrailerEditScene.self, from: legacy)
        XCTAssertNil(old.actionStart)
        XCTAssertNil(old.actionEnd)
        let bad = #"{"id":1,"sourceID":1,"start":3,"length":4,"actionStart":7,"actionEnd":3}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(TrailerEditScene.self, from: bad).actionStart)
        // 구버전 초안은 저장된 창 전체로 이관된다.
        let source = spikeSource(id: 1, spike: 10, peakTimes: [10.5])
        var legacyScenes = [old]
        TrailerSceneEditor.migrateLegacyActionWindows(scenes: &legacyScenes, sources: [source])
        XCTAssertEqual(legacyScenes[0].actionStart, 3.0)
        XCTAssertEqual(legacyScenes[0].actionEnd, 7.0)
    }
    /// 자동 추천(장면 목록 없음)에서 음악 맞춤을 부르면 음악 예산으로 줄인 목록이 아니라 전체 추천에서 시작해, 마지막 샷과 보호 창이 모두 남는다.
    func testAutoPlanMusicFitKeepsTailAndProtectedWindows() {
        let sources = (1...4).map { spikeSource(id: $0, spike: 10, peakTimes: [10.5]) }
        let music = TrailerMusicSelection(recordID: UUID(), name: "m", url: URL(fileURLWithPath: "/dummy"), duration: 6, policy: .fitMusic)
        let clip = 4.0
        // 짧은 길이(6초)로 시드해도 보호 동작이 있는 소스는 빠지지 않는다(예전 자동 총길이는 예산이 아님: 정한 길이만 장면을 뺀다).
        // 맞춤 시드도 전체 추천에서 시작한다.
        let short = TrailerPreparedPlan.seedEdits(mode: .trailer, sources: sources, total: 6, clipLength: clip)
        let seeded = TrailerPreparedPlan.seedEdits(mode: .trailer, sources: sources, total: 6, clipLength: clip, music: music)
        XCTAssertEqual(short.filter { !$0.excluded }.map(\.sourceID), [1, 2, 3, 4], "정하지 않은 길이 때문에 보호된 샷이 빠지면 안 됩니다.")
        XCTAssertGreaterThan(short.reduce(0.0) { $0 + $1.length }, 6.0)
        XCTAssertEqual(seeded.filter { !$0.excluded }.map(\.sourceID), [1, 2, 3, 4], "마지막 샷까지 전체 추천이 들어와야 합니다.")
        let anchors = seeded.map { ($0.actionStart, $0.actionEnd) }
        var fitted = seeded
        let result = TrailerSceneEditor.fitScenesToMusic(scenes: &fitted, sources: sources, musicDuration: 6, startCount: 3,
                                                         cardsDuration: .infinity, maximumRepeats: 600)
        XCTAssertTrue(result.fits)
        XCTAssertEqual(result.count, 3, "고른 반복 횟수 그대로입니다.")
        XCTAssertLessThanOrEqual(result.total, 18.0 + 1e-6)
        XCTAssertFalse(fitted.filter { !$0.excluded }.isEmpty)
        for (index, scene) in fitted.enumerated() {
            guard let a = anchors[index].0, let b = anchors[index].1 else { continue }
            if let newStart = scene.actionStart, let newEnd = scene.actionEnd, abs(newStart - a) > 1e-6 || abs(newEnd - b) > 1e-6 {
                // 남는 자리에 맞춰 피크 중심으로 좁힌 장면: 좁힌 창이 새 보호 구간이고, 기존 구간 안에서 실제 피크(10.5초)를 담는다.
                XCTAssertGreaterThanOrEqual(newStart, a - 1e-6)
                XCTAssertLessThanOrEqual(newEnd, b + 1e-6)
                XCTAssertLessThanOrEqual(newStart, 10.5)
                XCTAssertGreaterThanOrEqual(newEnd, 10.5)
                XCTAssertLessThanOrEqual(scene.start, newStart + 1e-6)
                XCTAssertGreaterThanOrEqual(scene.start + scene.length, newEnd - 1e-6, "좁힌 보호 구간이 창 밖으로 밀리면 안 됩니다.")
                continue
            }
            XCTAssertLessThanOrEqual(scene.start, a + 1e-6)
            XCTAssertGreaterThanOrEqual(scene.start + scene.length, b - 1e-6, "보호된 동작 구간이 창 밖으로 밀리면 안 됩니다.")
        }
    }

    // MARK: 조용한 임팩트(onset) 보호 / 비트 최소 반복 / 분석 영속

    /// 파형 0.5초 단위 44칸 중 4~7초가 지속 소음이고, 검증된 피크는 그 소음 한가운데(5.628), 조용한 클릭(3.614)이 그 앞에 있다.
    private func quietClickSource(transients: [Double]) -> VideoTrailerSource {
        var wave = [Double](repeating: 0.05, count: 44)
        for index in 8..<14 { wave[index] = 0.8 }
        let analysis = AudioAnalysisResult(waveform: wave, peakTime: 5.628, peakTimes: [5.628, 3.614], audioAvailability: .present,
                                           highlightSource: .audio, verifiedPeakTimes: [5.628], transientTimes: transients)
        return VideoTrailerSource(id: 1, name: "putt", url: URL(fileURLWithPath: "/dummy"),
                                  plan: VideoTrailerPlan(analysis: analysis, duration: 22), isImage: false)
    }

    /// 더 큰 지속 소음보다 앞선 조용한 고립 타격이 스트로크의 시작이다: 보호 구간과 추천 사본 창이 그 타격을 포함한다.
    /// 타격 정보가 없으면 기존처럼 피크 기준이다.
    func testQuietImpactBeforeLouderSustainedPeakStaysInsideProtectedWindow() {
        let quiet = quietClickSource(transients: [3.614])
        let lead = VideoTrailerPlan.actionLeadSeconds, follow = VideoTrailerPlan.actionFollowSeconds
        let action = quiet.plan.protectedInterval(start: 3.6, length: 4.0)
        XCTAssertEqual(action.start, 3.614 - lead, accuracy: 1e-9)
        XCTAssertEqual(action.end, 5.628 + follow, accuracy: 1e-9)
        let window = quiet.plan.actionWindow(start: 3.6, length: 4.0)
        XCTAssertEqual(window.start, action.start, accuracy: 1e-9, "보호 구간이 요청 길이보다 길면 창이 보호 구간 전체로 넓어집니다.")
        XCTAssertEqual(window.length, action.end - action.start, accuracy: 1e-9)
        let kept = quietClickSource(transients: []).plan.protectedInterval(start: 3.6, length: 4.0)
        XCTAssertEqual(kept.start, 5.628 - lead, accuracy: 1e-9, "타격 정보가 없으면 기존 피크 기준입니다.")
        // 피크보다 3.8초를 넘게 앞선 타격은 같은 동작이 아니다.
        XCTAssertEqual(quietClickSource(transients: [1.0]).plan.protectedInterval(start: 3.6, length: 4.0).start, 5.628 - lead, accuracy: 1e-9)

        let rebuilt = TrailerSceneEditor.rebuiltFromRecommendation(
            scenes: [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 4.0)], sources: [quiet])[0]
        XCTAssertEqual(rebuilt.actionStart ?? -1, 3.614 - lead, accuracy: 1e-9)
        XCTAssertEqual(rebuilt.actionEnd ?? -1, 5.628 + follow, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(rebuilt.start, (rebuilt.actionStart ?? 0) + 1e-9, "창이 조용한 스트로크 앞부분을 잘라내면 안 됩니다.")
        XCTAssertGreaterThanOrEqual(rebuilt.start + rebuilt.length, (rebuilt.actionEnd ?? .infinity) - 1e-9)
        // 클릭 없는 소리는 연습·준비 소리일 수 있어 뒤(소리 없는 실제 스트로크·결과)를 더 길게 지킨다(Android와 같은 규칙).
        let plain = TrailerSceneEditor.rebuiltFromRecommendation(
            scenes: [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 4.0)], sources: [quietClickSource(transients: [])])[0]
        XCTAssertEqual(plain.actionEnd ?? -1, 5.628 + VideoTrailerPlan.weakActionFollowSeconds, accuracy: 1e-9)
    }

    /// 긴 라운드 영상의 조용한 고립 타격은 소리 크기 순위·소스당 한도(8)와 상관없이 모두 사본에 들어간다(Android와 같은 규칙).
    /// 큰 소리(바람·카트)만으로는 장면이 늘지 않는다.
    func testRebuiltCopyKeepsEveryIsolatedHitOfALongRound() {
        let hits = (0..<12).map { 10.0 + Double($0) * 24.0 }
        let loud = (0..<12).map { 21.0 + Double($0) * 24.0 }
        let wave = (0..<600).map { i in loud.contains { abs(Double(i) / 2.0 - $0) < 0.6 } ? 0.9 : 0.05 }
        func round(_ transients: [Double]) -> VideoTrailerSource {
            VideoTrailerSource(id: 1, name: "round", url: URL(fileURLWithPath: "/dummy"),
                plan: VideoTrailerPlan(analysis: AudioAnalysisResult(waveform: wave, peakTime: loud[0], peakTimes: loud, audioAvailability: .present,
                    highlightSource: .audio, transientTimes: transients), duration: 300), isImage: false)
        }
        var nextID = 2
        let rebuilt = TrailerSceneEditor.rebuiltFromRecommendation(
            scenes: [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 4, caption: TrailerCaption(text: "라운드"))], sources: [round(hits)], nextID: &nextID)
        XCTAssertEqual(rebuilt.count, 12)
        for hit in hits {
            XCTAssertTrue(rebuilt.contains { $0.start <= hit - 1.0 && $0.start + $0.length >= hit + 1.0 }, "hit \(hit)")
        }
        XCTAssertEqual(Set(rebuilt.map(\.id)).count, 12)
        XCTAssertEqual(nextID, 13)
        XCTAssertEqual(rebuilt.filter { $0.caption != nil }.count, 1, "자막은 원래 장면에만 남습니다.")
        XCTAssertTrue(zip(rebuilt, rebuilt.dropFirst()).allSatisfy { $0.start + $0.length <= $1.start + 1e-6 }, "소스 시간순, 겹치지 않음")
        // 고립 타격이 없으면 기존 장면 수 그대로(큰 소리만으로는 늘지 않는다).
        XCTAssertEqual(TrailerSceneEditor.rebuiltFromRecommendation(scenes: [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 4)], sources: [round([])]).count, 1)
    }

    /// 고립 타격 3.45초 앞의 검증된 스윙은 버려지지 않고 한 동작으로 합쳐진다.
    func testVerifiedHitNextToAKeptShotWidensIt() {
        let wave = (0..<100).map { (16...18).contains($0) || (33...35).contains($0) ? 0.9 : 0.05 }
        let source = VideoTrailerSource(id: 1, name: "a", url: URL(fileURLWithPath: "/dummy"),
            plan: VideoTrailerPlan(analysis: AudioAnalysisResult(waveform: wave, peakTime: 8.62, peakTimes: [8.62, 5.17], audioAvailability: .present,
                highlightSource: .audio, verifiedPeakTimes: [8.62, 5.17], transientTimes: [8.62]), duration: 50), isImage: false)
        let picks = source.plan.actionPicks(clipLength: 4)
        XCTAssertEqual(picks.count, 1)
        XCTAssertEqual(picks[0].actionStart, 5.17 - VideoTrailerPlan.actionLeadSeconds, accuracy: 1e-9)
        XCTAssertEqual(picks[0].actionEnd, 8.62 + VideoTrailerPlan.actionFollowSeconds, accuracy: 1e-9)
    }

    /// 클립 길이 줄: 추천과 같은 4초라도 숫자 4는 정확히 4초(임팩트 포함), 추천은 동작 전체 보호. 숫자 1은 음악 맞춤이 다시 늘리지 않는다.
    func testNumericClipIsExactEvenWhenItEqualsTheRecommendationAndMusicOnlyCapsIt() {
        let source = spikeSource(id: 1, duration: 40, spike: 10, peakTimes: [20.5])
        let interval = source.plan.rankedActionPeaks().first!.interval(duration: 40)
        let scene = TrailerEditScene(id: 1, sourceID: 1, start: interval.start, length: interval.end - interval.start,
                                     actionStart: interval.start, actionEnd: interval.end)
        var recommended = [scene], numeric = [scene]
        TrailerSceneEditor.applyClipChoice(clipLength: 4, recommended: true, scenes: &recommended, sources: [source])
        TrailerSceneEditor.applyClipChoice(clipLength: 4, recommended: false, scenes: &numeric, sources: [source])
        XCTAssertGreaterThanOrEqual(TrailerSceneEditor.sceneDurationBounds(scene: recommended[0], source: source).minimum, interval.end - interval.start - 1e-6)
        XCTAssertEqual(numeric[0].length, 4, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(numeric[0].start, 20.5)
        XCTAssertGreaterThanOrEqual(numeric[0].start + numeric[0].length, 20.5)
        var one = [scene]
        TrailerSceneEditor.applyClipChoice(clipLength: 1, recommended: false, scenes: &one, sources: [source])
        let capped = TrailerSceneEditor.fitScenesToMusic(scenes: &one, sources: [source], musicDuration: 10, startCount: 1, cardsDuration: 0,
                                                         maximumRepeats: 600, capOnly: true)
        XCTAssertEqual(capped.count, 1)
        XCTAssertEqual(one[0].length, 1, accuracy: 1e-9, "숫자로 고른 1초 컷은 음악 길이에 맞추려고 다시 늘지 않습니다.")
        let filled = TrailerSceneEditor.fitScenesToMusic(scenes: &one, sources: [source], musicDuration: 10, startCount: 1, cardsDuration: 0,
                                                         maximumRepeats: 600)
        XCTAssertEqual(filled.total, 10, accuracy: 1e-3)
    }

    /// 전체 길이 예산 3→5→3: 같은 장면이 빠지고, 늘리면 제자리로 돌아오며, 가장 짧은 한 장면보다 짧으면 받지 않는다.
    func testBudgetRoundTripRestoresReservedScenes() {
        let sources = (1...3).map { spikeSource(id: $0, duration: 40, spike: 5, peakTimes: [10.5]) }
        let original = (1...3).map { TrailerEditScene(id: $0, sourceID: $0, start: 9.0, length: 4.0, volume: 0.4, actionStart: 9.0, actionEnd: 13.0) }
        var scenes = original
        // 4초 두 장면이 통째로 들어가고 남는 1초에 세 번째 장면이 빠지는 대신 피크(10.5초) 중심으로 좁혀 담긴다.
        let short = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 9)
        XCTAssertEqual(short?.included, 3)
        XCTAssertEqual(short?.excluded, 0)
        XCTAssertEqual(short?.total ?? 0, 9, accuracy: 1e-3)
        XCTAssertEqual(scenes[0].length, 4, accuracy: 1e-3)
        XCTAssertEqual(scenes[1].length, 4, accuracy: 1e-3)
        XCTAssertEqual(scenes[2].length, 1, accuracy: 1e-3)
        XCTAssertLessThanOrEqual(scenes[2].start, 10.5)
        XCTAssertGreaterThanOrEqual(scenes[2].start + scenes[2].length, 10.5)
        XCTAssertGreaterThanOrEqual(scenes[2].start, 9.0 - 1e-9)
        XCTAssertLessThanOrEqual(scenes[2].start + scenes[2].length, 13.0 + 1e-9)
        let shortChoice = scenes.map(\.excluded)
        let long = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 15)
        XCTAssertEqual(long?.excluded, 0)
        XCTAssertEqual(long?.total ?? 0, 15, accuracy: 1e-3)
        XCTAssertEqual(scenes.map(\.id), [1, 2, 3])
        XCTAssertTrue(scenes.allSatisfy { $0.volume == 0.4 })
        TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 9)
        XCTAssertEqual(scenes.map(\.excluded), shortChoice)
        // 가장 짧은 한 장면보다 짧은 목표도 받는다: 가장 원하는 장면 하나의 동작 구간이 실제 피크(10.5초)를 담도록 요청한 3초로 좁아진다.
        scenes = original
        let tiny = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 3)
        XCTAssertEqual(tiny?.total ?? 0, 3, accuracy: 1e-3)
        XCTAssertEqual(tiny?.included, 1)
        let kept = scenes.filter { !$0.excluded }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].length, 3, accuracy: 1e-3)
        XCTAssertLessThanOrEqual(kept[0].start, 10.5, "좁힌 창이 실제 피크를 담습니다.")
        XCTAssertGreaterThanOrEqual(kept[0].start + kept[0].length, 10.5)
        XCTAssertGreaterThanOrEqual(kept[0].start, 9.0 - 1e-9, "기존 동작 구간 안의 시각만 씁니다.")
        XCTAssertLessThanOrEqual(kept[0].start + kept[0].length, 13.0 + 1e-9)
        XCTAssertEqual(kept[0].volume, 0.4)
        XCTAssertEqual(scenes.map(\.id), [1, 2, 3])
        XCTAssertEqual(TrailerSceneEditor.budgetBodyBounds(scenes: scenes, sources: sources).minimum, 3, accuracy: 1e-9,
                       "좁힌 동작 구간이 새 보호 구간이라 가장 짧은 한 장면은 3초입니다.")
    }

    /// 고립된 짧은 타격만 transient: 큰 소리라도 지속되면(2~3프레임 뒤에도 35% 넘게 남으면) 아니고, 들리지 않는 소리(<0.04)도 아니다.
    func testIsolatedTransientTimesFindsOnlyShortSharpHits() {
        var peaks = [Double](repeating: 0.008, count: 40)
        peaks[10] = 0.074          // 조용하지만 바닥의 9배, 곧 사라짐 → transient
        peaks[20] = 0.03           // 6배 넘지만 0.04 미만 → 아님
        for index in 25..<35 { peaks[index] = 0.7 }   // 지속 소음 → 시작해도 곧 사라지지 않음 → 아님
        let frames = peaks.enumerated().map { index, peak in
            AudioImpactFrame(time: Double(index) * 0.1, metrics: AudioImpactMetrics(rms: peak / 2, peak: peak, crossingRate: 0))
        }
        XCTAssertEqual(AudioAnalysisService.isolatedTransientTimes(frames), [1.0])
    }

    /// 비트 맞춤은 고른 반복 횟수 그대로이고 예산(음악 끝, 다른 정책은 지금 총길이)을 넘기지 않으며 보호 구간을 지킨다.
    func testBeatSyncKeepsTheChosenRepeatCountAndBudget() {
        let sources = (1...6).map { spikeSource(id: $0, duration: 40, spike: 10, peakTimes: [10.5]) }
        func scenes() -> [TrailerEditScene] {
            (1...6).map { TrailerEditScene(id: $0, sourceID: $0, start: 9.0, length: 1.6, actionStart: 9.0, actionEnd: 10.6) }
        }
        let beats = (0..<10).map(Double.init)
        let tight = TrailerMusicSelection(recordID: UUID(), name: "m", url: URL(fileURLWithPath: "/dummy"), duration: 10, policy: .fitMusic, fitCount: 1)
        let chosen = TrailerSceneEditor.syncToBeatsWithMinimumRepeats(
            scenes: scenes(), sources: sources, beatOnsets: beats, music: tight, cardsDuration: 0, introOffset: 0, outroDuration: 0)
        XCTAssertEqual(chosen.fitCount, 1)
        XCTAssertLessThanOrEqual(chosen.scenes.filter { !$0.excluded }.reduce(0.0) { $0 + $1.length }, 10.0 + 0.05)
        for (index, scene) in chosen.scenes.enumerated() {
            XCTAssertLessThanOrEqual(scene.start, 9.0 + 1e-6, "scene \(index): 보호 구간 시작이 창 안에 있어야 합니다.")
            XCTAssertGreaterThanOrEqual(scene.start + scene.length, 10.6 - 1e-6, "scene \(index): 보호 구간 끝이 창 안에 있어야 합니다.")
        }
        // 음악 반복 정책도 지금 총길이(9.6초)를 넘기지 않는다.
        let looped = TrailerMusicSelection(recordID: UUID(), name: "m", url: URL(fileURLWithPath: "/dummy"), duration: 10, policy: .loopMusic)
        let loop = TrailerSceneEditor.syncToBeatsWithMinimumRepeats(
            scenes: scenes(), sources: sources, beatOnsets: beats, music: looped, cardsDuration: 0, introOffset: 0, outroDuration: 0)
        XCTAssertEqual(loop.fitCount, 1)
        XCTAssertLessThanOrEqual(loop.scenes.reduce(0.0) { $0 + $1.length }, 9.6 + 1e-6)
    }

    /// 조용한 임팩트 근거(transientTimes)는 저장·재열기에서 유지되고, 구버전 저장본(키 없음)은 nil로 읽혀 열 때 다시 분석한다.
    func testTransientEvidenceRoundTripsAndLegacyRowReadsNil() throws {
        let json = #"{"id":3,"name":"a.mp4","file":"a.mp4","isImage":false,"duration":22.7,"imageDurationRatio":0.55,"waveform":[0.1],"peakTime":1,"peakTimes":[1],"highlightSource":"audio","audioAvailability":"present","highlightAnalyzed":true,"verifiedPeakTimes":[1.0]%@}"#
        let legacy = try JSONDecoder().decode(TrailerProjectRecord.Source.self, from: json.replacingOccurrences(of: "%@", with: "").data(using: .utf8)!)
        XCTAssertNil(legacy.transientTimes)
        XCTAssertEqual(legacy.verifiedPeakTimes, [1.0])
        let current = try JSONDecoder().decode(TrailerProjectRecord.Source.self, from: json.replacingOccurrences(of: "%@", with: #","transientTimes":[3.614]"#).data(using: .utf8)!)
        XCTAssertEqual(current.transientTimes, [3.614])
        let again = try JSONDecoder().decode(TrailerProjectRecord.Source.self, from: try JSONEncoder().encode(current))
        XCTAssertEqual(again.transientTimes, [3.614])
    }

    /// 클립 순서(촬영순·추가순·랜덤)와 분석 이후 수동 장면 타임라인 재정렬은 보호 구간·편집값·소스 내 분할 순서를 보존한다.
    func testClipOrderChoicesAndSceneReorderingPreserveProtectedAndEditedFields() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let analysis = AudioAnalysisResult(
            waveform: [], peakTime: 0, peakTimes: [],
            audioAvailability: .unknown, highlightSource: .fallback
        )
        let s0 = VideoTrailerSource(
            id: 0, name: "clip_c.mp4", url: URL(fileURLWithPath: "/dummy/0.mp4"),
            plan: VideoTrailerPlan(analysis: analysis, duration: 20), isImage: false, captureDate: baseDate.addingTimeInterval(300)
        )
        let s1 = VideoTrailerSource(
            id: 1, name: "clip_a.mp4", url: URL(fileURLWithPath: "/dummy/1.mp4"),
            plan: VideoTrailerPlan(analysis: analysis, duration: 20), isImage: false, captureDate: baseDate.addingTimeInterval(100)
        )
        let s2 = VideoTrailerSource(
            id: 2, name: "clip_b.mp4", url: URL(fileURLWithPath: "/dummy/2.mp4"),
            plan: VideoTrailerPlan(analysis: analysis, duration: 20), isImage: false, captureDate: baseDate.addingTimeInterval(200)
        )

        let chronological = VideoTrailerSourceOrder.chronological([s0, s1, s2])
        XCTAssertEqual(chronological.map(\.id), [1, 2, 0])

        let added = VideoTrailerSourceOrder.added(chronological)
        XCTAssertEqual(added.map(\.id), [0, 1, 2])

        let randomized = VideoTrailerSourceOrder.randomized(added)
        XCTAssertEqual(Set(randomized.map(\.id)), [0, 1, 2])
        XCTAssertNotEqual(randomized.map(\.id), added.map(\.id))

        var scenes = [
            TrailerEditScene(
                id: 11, sourceID: 0, start: 8.0, length: 4.5, excluded: true, budgetExcluded: true,
                muted: true, fitsFrame: true, volume: 0.35, offsetX: 0.2, offsetY: -0.1,
                caption: TrailerCaption(text: "보존 자막"),
                actionStart: 8.5, actionEnd: 12.0
            ),
            TrailerEditScene(id: 10, sourceID: 0, start: 1.0, length: 3.0, volume: 0.8),
            TrailerEditScene(id: 12, sourceID: 1, start: 2.0, length: 2.5, actionStart: 2.2, actionEnd: 4.2),
            TrailerEditScene(id: 13, sourceID: 2, start: 0.0, length: 3.5)
        ]

        let randomReordered = TrailerSceneEditor.reorderScenesBySourceOrder(
            scenes: scenes,
            sourceIDs: randomized.map(\.id)
        )
        XCTAssertEqual(randomReordered.filter { $0.sourceID == 0 }.map(\.id), [10, 11])

        scenes = TrailerSceneEditor.reorderScenesBySourceOrder(scenes: scenes, sourceIDs: chronological.map(\.id))
        XCTAssertEqual(scenes.map(\.id), [12, 13, 10, 11])
        let preserved = scenes[3]
        XCTAssertEqual(preserved.id, 11)
        XCTAssertEqual(preserved.sourceID, 0)
        XCTAssertEqual(preserved.start, 8.0, accuracy: 1e-9)
        XCTAssertEqual(preserved.length, 4.5, accuracy: 1e-9)
        XCTAssertTrue(preserved.excluded)
        XCTAssertTrue(preserved.budgetExcluded)
        XCTAssertTrue(preserved.muted)
        XCTAssertTrue(preserved.fitsFrame)
        XCTAssertEqual(preserved.volume, 0.35, accuracy: 1e-9)
        XCTAssertEqual(preserved.caption?.text, "보존 자막")
        XCTAssertEqual(preserved.actionStart ?? -1, 8.5, accuracy: 1e-9)
        XCTAssertEqual(preserved.actionEnd ?? -1, 12.0, accuracy: 1e-9)
    }
}

// MARK: - 실제 AVFoundation 파이프라인 하네스 (today54)

/// `PhotoSelectionEngineTests` 선택자에는 들어가지 않는 별도 클래스라 평소 설치 검증(29개)을 바꾸지 않는다.
/// `<root>/run.json`이 있을 때만 돌고, 없으면 건너뛴다.
final class ShotFixRenderHarnessTests: XCTestCase {
    /// 안드로이드 '오늘 54미디어' 초안과 같은 입력(원본 54개·72장면·음악)을 앱의 실제 파이프라인으로 끝까지 만든다.
    @MainActor
    func testShotFixToday54ActualPipeline() async throws {
        guard let root = ShotFixHarness.root(),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("run.json").path) else {
            throw XCTSkip("run.json 없음: 실제 렌더 하네스는 요청 파일이 있을 때만 실행합니다.")
        }
        let failures = try await ShotFixHarness(root: root).execute()
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}

private struct ShotFixManifest: Decodable {
    struct Source: Decodable { let id: Int; let name: String; let sha256: String; let bytes: Int64; let isImage: Bool; let duration: Double }
    struct Scene: Decodable { let key: Int; let sourceId: Int; let start: Double; let length: Double; let volume: Double }
    struct Music: Decodable { let name: String; let file: String; let sha256: String; let duration: Double }
    let clipLength: Double
    let total: Double
    let music: Music
    let sources: [Source]
    let scenes: [Scene]
}

/// policy: fitMusic(기본)/loopMusic/single, fitCount: 요청 반복 횟수, beat: 비트 맞춤 적용,
/// useSharedStore: 앱의 실제 편집본 목록에 원본(이관)·사본을 남김(기본은 격리 저장소), cleanup: 끝난 뒤 이 하네스의 입력 사본을 지움.
private struct ShotFixRun: Decodable {
    let label: String
    let policy: String?
    let fitCount: Int?
    let beat: Bool?
    let useSharedStore: Bool?
    let cleanup: Bool?
    /// true면 맞춤·비트까지의 계획(plan-only.json)만 쓰고 렌더하지 않는다(계획 검증용).
    let planOnly: Bool?
    /// 정리 전용 요청: 이 하네스가 공유 저장소에 만든 검증 프로젝트(제목이 "[검증 fit-beat-r"로 시작하는 정확한 id만)를 지우고,
    /// removeFixture면 입력·결과 폴더(shot-fix-today54) 전체를 지운다. 사용자 프로젝트는 건드리지 않는다.
    let deleteProjects: [String]?
    let removeFixture: Bool?
    /// 정리 전용: 남길 검증 사본 하나의 정확한 id와 새 제목(제목이 "[검증 fit-beat-r"로 시작할 때만 바꾼다).
    let keepProject: String?
    let keepTitle: String?
    /// 원시 입력 폴더(raw/, music/) 대신 공유 저장소의 이 편집본 자기 폴더 파일(같은 이름)을 읽기 전용 입력으로 쓴다. sha256은 manifest로 그대로 검사한다.
    let inputProject: String?
    /// 정리 전용: 남길 사본의 완성 영상을 앱의 '폰하드에 저장'과 같은 SharedInboxStore.importDownloadedFile로 폰하드에 복사한다(재렌더 없이 파일 보기용).
    let saveKeptOutput: Bool?
    /// 화면의 '전체 길이'(setManualTotal)와 같은 예산 맞춤(초, 카드 없음). 음악은 반복(loopMusic)으로 영상 끝까지 깐다.
    let totalSeconds: Double?
    /// true면 합성 빨강/파랑 영상으로 고급 편집(배속·디졸브·큐·색상·키프레임·해설·짧은 목표)을 앱의 실제 렌더로 만들고 출력 파일에서 길이·화소·소리를 읽는다.
    let advanced: Bool?
    /// 전체 길이 예산을 차례로(예: 180,300,180) 맞추고 음악 맞춤 1→2회까지, 매번 저장 → 새 저장소로 재로드해 같은지 기록한다(totalSeconds가 있으면 이어서 렌더).
    let budgetSequence: [Double]?
}

private enum ShotFixError: Error { case timeout(String) }

private func shotFixSHA256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    // 청크마다 autorelease를 비운다. 그러지 않으면 4GB를 읽는 동안 메모리가 쌓여 테스트 호스트가 종료된다.
    var finished = false
    while !finished {
        try autoreleasepool {
            if let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) } else { finished = true }
        }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// 원본 이관 프로젝트 저장 → 제품의 '추천으로 다시 맞춘 사본' → 재열기(copyStoredFiles/adopt) → 음악 맞춤·비트 맞춤(뷰와 같은 정적 함수) →
/// VideoTrailerModel.start(generate: true) → 완성 영상 저장 → 새 저장소 인스턴스로 재로드. 결과는 `<root>/out-<label>/`.
@MainActor
private final class ShotFixHarness {
    private let root: URL
    private let manifest: ShotFixManifest
    private let run: ShotFixRun
    private let out: URL
    private var report: [String: Any] = [:]
    private var failures: [String] = []
    /// inputProject가 있을 때 manifest 상대 경로(raw/<name>, music/<file>) → 그 편집본 폴더의 실제 파일.
    private var inputFiles: [String: URL] = [:]

    private func input(_ relative: String) -> URL { inputFiles[relative] ?? root.appendingPathComponent(relative) }

    static func root() -> URL? {
        if let path = ProcessInfo.processInfo.environment["NASFINDER_SHOTFIX_DIR"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("shot-fix-today54")
    }

    init(root: URL) throws {
        self.root = root
        manifest = try JSONDecoder().decode(ShotFixManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        run = try JSONDecoder().decode(ShotFixRun.self, from: Data(contentsOf: root.appendingPathComponent("run.json")))
        out = root.appendingPathComponent("out-\(run.label)", isDirectory: true)
    }

    func execute() async throws -> [String] {
        if run.deleteProjects != nil || run.removeFixture == true { return await cleanupOnly() }
        let started = Date()
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        note("label", run.label)
        note("startedAt", stamp(started))
        log("시작 \(run.label)")
        do { try await pipeline() } catch { fail("파이프라인 예외: \(error)") }
        note("failures", failures)
        note("finishedAt", stamp())
        note("elapsedSeconds", Date().timeIntervalSince(started))
        log("끝 failures=\(failures.count)")
        // 같은 요청이 평소 테스트 실행에서 다시 돌지 않게 요청 파일을 결과 이름으로 바꾼다.
        let marked = root.appendingPathComponent("run-\(run.label).\(failures.isEmpty ? "done" : "failed").json")
        try? FileManager.default.removeItem(at: marked)
        try? FileManager.default.moveItem(at: root.appendingPathComponent("run.json"), to: marked)
        return failures
    }

    private func pipeline() async throws {
        let fm = FileManager.default
        let service = TrailerProjectMediaService()
        if let text = run.inputProject {
            guard let id = UUID(uuidString: text), let record = TrailerProjectStore.shared.records[id] else { fail("inputProject 없음: \(text)"); return }
            for source in record.sources { inputFiles["raw/\(source.name)"] = TrailerProjectStore.shared.fileURL(source.file, id: id) }
            if let music = record.music, music.name == manifest.music.name { inputFiles[manifest.music.file] = TrailerProjectStore.shared.fileURL(music.file, id: id) }
            note("inputProject", text)
        }
        let items = manifest.sources.map { source -> RemoteFileItem in
            let url = input("raw/\(source.name)")
            return RemoteFileItem(connectionID: TrailerProjectMediaService.connectionID, path: url.path, name: source.name, kind: .file,
                                  size: source.bytes, modifiedAt: nil,
                                  contentTypeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier)
        }
        let info = Bundle.main.infoDictionary
        note("app", "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))")
        note("platform", ProcessInfo.processInfo.isMacCatalystApp ? "mac-catalyst" : "\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)")
        guard manifest.sources.map(\.id) == Array(0..<manifest.sources.count) else { fail("manifest 소스 id가 0...N-1이 아닙니다."); return }

        // 1. 용량과 입력 무결성(원본 sha256이 manifest와 같아야 한다)
        let rawBytes = manifest.sources.reduce(Int64(0)) { $0 + $1.bytes }
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        note("rawBytes", rawBytes)
        note("freeBytesAtStart", free)
        // 원본 사본 + 원본 이관 프로젝트 + 사본 + 재열기 작업 사본 + 중간 산출물
        guard free > rawBytes * 9 / 2 + 2_000_000_000 else { fail("여유 공간 부족: \(free) bytes"); return }
        let mismatched = await mismatchedInputs()
        note("inputShaMismatch", mismatched)
        guard mismatched.isEmpty else { fail("입력 sha256 불일치: \(mismatched)"); return }

        // 2. 실제 모델로 54개를 준비(실제 오디오·시각 분석)
        let model = VideoTrailerModel()
        model.start(items: items, service: service)
        try await wait("준비·분석", timeout: 3600, model: model) { model.isAwaitingSettings || model.error != nil }
        let byID = Dictionary(uniqueKeysWithValues: manifest.sources.map { ($0.id, $0) })
        guard model.error == nil, model.sources.count == manifest.sources.count, model.skippedCount == 0,
              model.sources.allSatisfy({ byID[$0.id]?.name == $0.name }) else {
            fail("준비 단계 이상: sources=\(model.sources.count) skipped=\(model.skippedCount) error=\(model.error ?? "-")")
            return
        }
        note("sources", model.sources.map { source -> [String: Any] in
            let analysis = source.plan.analysis
            return ["id": source.id, "file": source.name, "sha256": byID[source.id]?.sha256 ?? "", "isImage": source.isImage,
                    "duration": source.duration, "highlightSource": analysis.highlightSource.rawValue, "peakTime": analysis.peakTime,
                    "peakTimes": analysis.peakTimes, "verifiedPeakTimes": analysis.verifiedPeakTimes,
                    "transientTimes": analysis.transientTimes]
        })

        if run.advanced == true {
            do { try await advancedProof(model: model, items: items, service: service) } catch { fail("고급 렌더 예외: \(error)") }
            model.stop()
            return
        }

        // 3. 안드로이드 초안과 같은 상태(원본 순서·72장면·음악)의 '원본 프로젝트'를 저장. 앵커 도입 전 프로젝트와 같게 anchorsMigrated는 비운다.
        let musicURL = input(manifest.music.file)
        let musicDuration = try await TrailerMusic.usableDuration(of: musicURL)
        let music = TrailerMusicSelection(recordID: UUID(), name: manifest.music.name, url: musicURL, duration: musicDuration,
                                          policy: TrailerMusicPolicy(rawValue: run.policy ?? "fitMusic") ?? .fitMusic,
                                          fitCount: max(1, run.fitCount ?? 1))
        var order: [Int] = []
        for scene in manifest.scenes where !order.contains(scene.sourceId) { order.append(scene.sourceId) }
        for source in manifest.sources where !order.contains(source.id) { order.append(source.id) }
        let staged = Dictionary(uniqueKeysWithValues: model.sources.map { ($0.id, $0) })
        var draft = TrailerSettingsDraft(sources: order.compactMap { staged[$0] }, total: manifest.total, clipLength: manifest.clipLength,
                                         aspectRatio: nil, music: music)
        draft.scenes = manifest.scenes.map { TrailerEditScene(id: $0.key, sourceID: $0.sourceId, start: $0.start, length: $0.length, volume: $0.volume) }
        draft.nextSceneID = (manifest.scenes.map(\.key).max() ?? 0) + 1
        draft.knownIDs = Set(manifest.sources.map(\.id))
        let store = run.useSharedStore == true ? TrailerProjectStore.shared : TrailerProjectStore(root: root.appendingPathComponent("store-\(run.label)", isDirectory: true))
        let sourceID = UUID()
        var snapshot = model.projectSnapshot(id: sourceID, existing: nil, mode: .trailer, outputMode: nil, draft: draft,
                                             itemCount: items.count, selectedSceneID: nil, showedSettings: true)
        snapshot.record.customTitle = "[검증 \(run.label)] today54 원본(안드로이드 초안 이관)"
        snapshot.record.anchorsMigrated = nil
        guard await store.save(snapshot) else { fail("원본 프로젝트 저장 실패"); return }
        model.stop()
        let sourceJSON = store.folder(sourceID).appendingPathComponent("project.json")
        let sourceShaBefore = try shotFixSHA256(sourceJSON)
        noteDict("sourceProject", ["id": sourceID.uuidString, "projectJsonSha256Before": sourceShaBefore, "scenes": manifest.scenes.count])
        log("원본 프로젝트 저장 \(sourceID)")

        // 4. 제품의 '추천으로 다시 맞춘 사본'(원본은 그대로, 사본에서만 새 분석으로 창을 다시 고르고 음악에 맞춘다)
        guard let clone = await store.duplicateRebuiltFromRecommendation(sourceID), clone.rebuilt,
              let cloneRecord = store.records[clone.id] else { fail("추천으로 다시 맞춘 사본 실패"); return }
        let changed = zip(snapshot.record.scenes ?? [], cloneRecord.scenes ?? []).filter { abs($0.start - $1.start) > 1e-6 || abs($0.length - $1.length) > 1e-6 }.count
        noteDict("clone", ["id": clone.id.uuidString, "title": cloneRecord.customTitle ?? "", "scenes": cloneRecord.scenes?.count ?? 0,
                       "changedScenes": changed, "anchored": (cloneRecord.scenes ?? []).filter { $0.actionStart != nil }.count,
                       "policy": cloneRecord.music?.policy ?? "-", "fitCountAfterRebuild": cloneRecord.music?.fitCount ?? 0])
        log("사본 \(clone.id) 장면 변경 \(changed)")

        // 5. 재열기(앱이 편집본을 여는 경로)와 음악 맞춤·비트 맞춤(뷰의 fitManualScenesToMusic/runTempoSyncAction과 같은 정적 함수·같은 순서)
        let reopened = VideoTrailerModel()
        guard let restored = await reopened.copyStoredFiles(record: cloneRecord, store: store), restored.failed.isEmpty else {
            fail("사본 재열기 파일 복사 실패"); return
        }
        var edit = reopened.adopt(record: cloneRecord, restored: restored)
        var scenes = edit.scenes ?? []
        guard var selection = edit.music else { fail("사본에 음악이 없습니다."); return }
        let requestedCount = selection.fitCount
        if let sequence = run.budgetSequence {
            // 저장·재열기 왕복은 복사본으로 하고, 이어서 같은 실행에서 totalSeconds 렌더를 한다.
            await budgetRoundTrip(sequence, scenes: scenes, edit: edit, selection: selection, store: store, cloneID: clone.id, model: reopened, itemCount: items.count)
            if run.totalSeconds == nil { reopened.stop(); return }
        }
        if let whole = run.totalSeconds {
            guard let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: edit.sources, bodyTarget: whole) else { fail("전체 길이 \(whole)에 한 장면도 안 들어감"); return }
            selection.policy = .loopMusic
            selection.fitCount = 1
            edit.total = fit.total
            noteDict("budget", ["requested": whole, "actual": fit.total, "included": fit.included, "excluded": fit.excluded,
                            "reserved": scenes.filter(\.budgetExcluded).map { ["sourceID": $0.sourceID, "start": $0.start, "length": $0.length] }])
        }
        if selection.policy == .fitMusic {
            let fit = TrailerSceneEditor.fitScenesToMusic(scenes: &scenes, sources: edit.sources, musicDuration: selection.duration,
                                                          startCount: selection.fitCount, cardsDuration: 0,
                                                          maximumRepeats: TrailerMusic.maximumRepeats)
            selection.fitCount = fit.count
            edit.total = selection.fittedDuration
            noteDict("fit", ["requestedCount": requestedCount, "effectiveCount": fit.count, "fits": fit.fits, "bodyTotal": fit.total])
        }
        let beats = try await AudioAnalysisService.extractBeatOnsets(url: selection.url, maxDuration: selection.duration)
        if run.beat == true {
            // 화면의 비트 버튼(runTempoSyncAction)과 같은 한 함수. 반복 횟수는 그대로이고 예산을 넘기지 않는다.
            let synced = TrailerSceneEditor.syncToBeatsWithMinimumRepeats(
                scenes: scenes, sources: edit.sources, beatOnsets: beats, music: selection,
                cardsDuration: 0, introOffset: 0, outroDuration: 0)
            let repeatsBefore = selection.fitCount
            scenes = synced.scenes
            selection.fitCount = synced.fitCount
            edit.total = selection.policy == .fitMusic && synced.fitCount != repeatsBefore
                ? selection.fittedDuration : scenes.filter { !$0.excluded }.reduce(0.0) { $0 + $1.length }
            noteDict("beatSync", ["adjusted": synced.result.adjustedCount, "unaligned": synced.result.unalignedCount,
                                  "averageShift": synced.result.averageShift, "fitResidual": synced.result.fitResidual,
                                  "repeatsBefore": repeatsBefore, "repeatsAfter": synced.fitCount])
        }
        edit.scenes = scenes
        edit.music = selection
        note("beatsDetected", beats.count)
        if run.planOnly == true {
            var cursor = 0.0
            let rows: [[String: Any]] = scenes.filter { !$0.excluded }.map { scene in
                defer { cursor += scene.length }
                return ["sourceID": scene.sourceID, "start": scene.start, "length": scene.length, "plannedStart": cursor,
                        "actionStart": scene.actionStart ?? NSNull(), "actionEnd": scene.actionEnd ?? NSNull()]
            }
            try JSONSerialization.data(withJSONObject: ["fitCount": selection.fitCount, "musicDuration": selection.duration, "beats": beats, "scenes": rows],
                                       options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("plan-only.json"), options: .atomic)
            note("planOnly", true)
            return
        }

        // 6. 실제 렌더: 앱의 만들기 버튼이 부르는 VideoTrailerModel.start(generate: true)
        let renderStart = Date()
        reopened.start(items: items, service: service, mode: .trailer, generate: true, sourceOrder: edit.sources.map(\.id),
                       total: edit.total, clipLength: edit.clipLength, aspectRatio: edit.aspectRatio, music: edit.music,
                       manualScenes: edit.scenes, draftSources: edit.sources,
                       revision: TrailerOutputRevision(signature: edit.signature, mode: .trailer),
                       introCard: edit.introCard, outroCard: edit.outroCard)
        try await wait("렌더·내보내기", timeout: 5400, model: reopened) { !reopened.isBusy }
        guard reopened.error == nil, let produced = reopened.outputURL, fm.fileExists(atPath: produced.path) else {
            fail("렌더 실패: \(reopened.error ?? "출력 없음") status=\(reopened.status)"); return
        }
        noteDict("render", ["seconds": Date().timeIntervalSince(renderStart), "status": reopened.status,
                        "recovered": reopened.recoveredCount, "excluded": reopened.skippedCount])
        if reopened.recoveredCount != 0 || reopened.skippedCount != 0 { fail("복구/제외 발생: recovered=\(reopened.recoveredCount) excluded=\(reopened.skippedCount)") }

        // 7. 실제로 방출된 계획·영상 사실: 장면별 원본(파일·sha), 보호 동작 구간 포함 여부, 음악 박자 정렬, 영상·오디오 트랙, 길이
        let emitted = reopened.scenes
        let included = (edit.scenes ?? []).filter { !$0.excluded }
        if emitted.count != included.count { fail("방출 장면 \(emitted.count) != 편집 장면 \(included.count)") }
        var plan: [[String: Any]] = []
        var violations: [Int] = []
        var boundaries: [Double] = []
        var cursor = 0.0
        for (index, scene) in emitted.enumerated() {
            let edited = index < included.count ? included[index] : nil
            var protectedOK = true
            if let a = edited?.actionStart, let b = edited?.actionEnd {
                protectedOK = scene.start <= a + 1e-3 && scene.start + scene.length >= b - 1e-3
                if !protectedOK { violations.append(index) }
            }
            let anchorStart: Any = edited?.actionStart ?? NSNull()
            let anchorEnd: Any = edited?.actionEnd ?? NSNull()
            plan.append(["index": index, "sourceID": scene.sourceID, "file": byID[scene.sourceID]?.name ?? "", "sha256": byID[scene.sourceID]?.sha256 ?? "",
                         "isImage": byID[scene.sourceID]?.isImage ?? false, "start": scene.start, "length": scene.length,
                         "plannedStart": cursor, "plannedEnd": cursor + scene.length, "muted": scene.muted, "fitsFrame": scene.fitsFrame,
                         "volume": scene.volume, "actionStart": anchorStart, "actionEnd": anchorEnd,
                         "protectedOK": protectedOK])
            cursor += scene.length
            if index < emitted.count - 1 { boundaries.append(cursor) }
        }
        let aligned = boundaries.enumerated().map { index, time -> (Int, Double, Bool) in
            let position = time.truncatingRemainder(dividingBy: selection.duration)
            let nearest = (beats + [selection.duration]).map { abs($0 - position) }.min() ?? .infinity
            return (index, nearest, nearest <= 0.05)
        }
        note("beatTimes", beats)
        note("boundaryNearestBeatDeltas", aligned.map(\.1))
        let within30 = boundaries.filter { time in
            let position = time.truncatingRemainder(dividingBy: selection.duration)
            return ((beats + [selection.duration]).map { abs($0 - position) }.min() ?? .infinity) <= 0.03
        }.count
        note("protectedViolations", violations)
        noteDict("beatAlignment", ["boundaries": boundaries.count, "alignedWithin50ms": aligned.filter { $0.2 }.count, "alignedWithin30ms": within30,
                               "boundaryTimes": boundaries,
                               "unaligned": aligned.filter { !$0.2 }.map { item -> [String: Any] in ["boundary": item.0, "nearestBeatDelta": item.1] }])
        let rendered = out.appendingPathComponent("render.mp4")
        try? fm.removeItem(at: rendered)
        try fm.copyItem(at: produced, to: rendered)
        let asset = AVURLAsset(url: rendered)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let size = try await videoTracks.first?.load(.naturalSize)
        let outputSha = try await Task.detached { try shotFixSHA256(rendered) }.value
        let assetSeconds = try await asset.load(.duration).seconds
        noteDict("video", ["seconds": assetSeconds, "plannedSeconds": cursor, "bytes": (try? rendered.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1,
                       "sha256": outputSha, "videoTracks": videoTracks.count, "audioTracks": audioTracks.count,
                       "width": Double(size?.width ?? 0), "height": Double(size?.height ?? 0), "sceneCount": emitted.count,
                       "musicSeconds": selection.duration, "musicFitCount": selection.fitCount, "musicPolicy": selection.policy.rawValue])
        if abs(assetSeconds - cursor) > 0.5 { fail("영상 길이 \(assetSeconds) != 계획 \(cursor)") }
        if videoTracks.isEmpty || audioTracks.isEmpty { fail("트랙 누락: video=\(videoTracks.count) audio=\(audioTracks.count)") }
        guard JSONSerialization.isValidJSONObject(plan) else { fail("plan.json 직렬화 불가"); return }
        try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("plan.json"), options: .atomic)

        // 8. 사본에 완성 영상까지 저장하고, 새 저장소 인스턴스(앱 재시작과 같은 디스크 로드)로 다시 읽어 같은지 확인
        let finished = reopened.projectSnapshot(id: clone.id, existing: store.records[clone.id], mode: .trailer, outputMode: .trailer,
                                                draft: edit, itemCount: items.count, selectedSceneID: nil, showedSettings: true,
                                                outputIsCurrent: true)
        guard await store.save(finished) else { fail("사본 저장 실패"); return }
        let reloaded = TrailerProjectStore(root: store.root)
        guard let again = reloaded.records[clone.id] else { fail("재로드에 사본이 없습니다."); return }
        let sameScenes = (again.scenes ?? []).count == scenes.count && zip(again.scenes ?? [], scenes).allSatisfy {
            $0.id == $1.id && $0.sourceID == $1.sourceID && abs($0.start - $1.start) < 1e-9 && abs($0.length - $1.length) < 1e-9
                && $0.actionStart == $1.actionStart && $0.actionEnd == $1.actionEnd && $0.excluded == $1.excluded
        }
        let reopenOK = sameScenes && again.music?.fitCount == selection.fitCount && again.outputFile != nil && reloaded.missing(again).isEmpty
        noteDict("reopen", ["sameScenes": sameScenes, "fitCount": again.music?.fitCount ?? 0, "hasOutput": again.outputFile != nil,
                        "missingFiles": reloaded.missing(again), "ok": reopenOK])
        if !reopenOK { fail("저장·재로드 불일치") }

        // 9. 원본 불변: 원본 프로젝트 파일과 입력 원본(sha256)이 그대로여야 한다.
        let sourceShaAfter = try shotFixSHA256(sourceJSON)
        let after = await mismatchedInputs()
        noteDict("unchanged", ["sourceProjectJson": sourceShaAfter == sourceShaBefore, "inputsMismatchedAfter": after])
        if sourceShaAfter != sourceShaBefore || !after.isEmpty { fail("원본이 바뀌었습니다.") }
        reopened.stop()
        if run.cleanup == true {
            // 이 하네스가 들여온 입력 사본만 지운다(결과 out-*는 남김). 공유 저장소의 프로젝트는 건드리지 않는다.
            for name in ["raw", "music"] + (run.useSharedStore == true ? [] : ["store-\(run.label)"]) { try? fm.removeItem(at: root.appendingPathComponent(name)) }
            note("cleanedUp", true)
        }
    }

    @MainActor
    /// 화면의 setManualTotal·chooseMusicPolicy와 같은 정적 함수로 예산을 차례로 맞추고, 매번 사본을 저장한 뒤 새 저장소 인스턴스로 다시 읽어 같은지 본다.
    private func budgetRoundTrip(_ sequence: [Double], scenes start: [TrailerEditScene], edit start0: TrailerSettingsDraft, selection start1: TrailerMusicSelection,
                                 store: TrailerProjectStore, cloneID: UUID, model: VideoTrailerModel, itemCount: Int) async {
        var scenes = start, edit = start0, selection = start1
        var rows: [[String: Any]] = []
        func violations(_ list: [TrailerEditScene]) -> Int {
            list.filter { !$0.excluded }.filter { s in
                guard let a = s.actionStart, let b = s.actionEnd, let src = edit.sources.first(where: { $0.id == s.sourceID }), !src.isImage else { return false }
                return s.start > a + 1e-5 || s.start + s.length < min(b, src.duration) - 1e-5
            }.count
        }
        func saveReload() async -> Bool {
            edit.scenes = scenes
            edit.music = selection
            let snap = model.projectSnapshot(id: cloneID, existing: store.records[cloneID], mode: .trailer, outputMode: nil, draft: edit,
                                             itemCount: itemCount, selectedSceneID: nil, showedSettings: true)
            guard await store.save(snap), let again = TrailerProjectStore(root: store.root).records[cloneID] else { return false }
            return again.scenes == scenes && again.music?.fitCount == selection.fitCount && again.music?.policy == selection.policy.rawValue
        }
        for whole in sequence {
            guard let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: edit.sources, bodyTarget: whole) else { fail("전체 길이 \(whole) 불가"); return }
            selection.policy = .loopMusic
            selection.fitCount = 1
            edit.total = fit.total
            let same = await saveReload()
            rows.append(["step": "total", "requested": whole, "actual": fit.total, "included": fit.included, "excluded": fit.excluded,
                         "excludedIDs": scenes.filter(\.budgetExcluded).map(\.id), "protectedViolations": violations(scenes), "reopenedSame": same])
            if !same || fit.total > whole + 1e-6 { fail("전체 길이 \(whole) 저장·재로드/예산 불일치") }
        }
        for count in 1...2 {
            selection.policy = .fitMusic
            selection.fitCount = count
            let fit = TrailerSceneEditor.fitScenesToMusic(scenes: &scenes, sources: edit.sources, musicDuration: selection.duration,
                                                          startCount: count, cardsDuration: 0, maximumRepeats: TrailerMusic.maximumRepeats)
            edit.total = selection.fittedDuration
            let same = await saveReload()
            rows.append(["step": "musicFit", "requested": count, "effective": fit.count, "musicWhole": selection.duration * Double(count), "actual": fit.total,
                         "fits": fit.fits, "excluded": fit.excluded, "included": scenes.filter { !$0.excluded }.count,
                         "protectedViolations": violations(scenes), "reopenedSame": same])
            if !same || fit.count != count || fit.total > selection.duration * Double(count) + 1e-6 { fail("음악 \(count)회 불일치") }
        }
        noteDict("budgetRoundTrip", ["rows": rows, "allScenes": scenes.count])
    }

    private func cleanupOnly() async -> [String] {
        let store = TrailerProjectStore.shared
        var deleted: [String] = [], skipped: [String] = []
        for text in run.deleteProjects ?? [] {
            // 이 하네스가 만든 검증 프로젝트, 또는 이전에 남긴 검증 사본(그 정확한 제목)만 지운다.
            guard let id = UUID(uuidString: text), let record = store.records[id],
                  (record.customTitle ?? "").hasPrefix("[검증 fit-beat-r") || record.customTitle == "완성된 예고편 (54개 미디어) — 샷 복구 (원본 보존)"
            else { skipped.append(text); continue }
            store.delete(id)
            deleted.append(text)
        }
        var renamed = false
        var savedOutput = ""
        var keptFilesOutsideFixture = true
        if let text = run.keepProject, let id = UUID(uuidString: text), let record = store.records[id],
           (record.customTitle ?? "").hasPrefix("[검증 fit-beat-r") {
            if let title = run.keepTitle { renamed = await store.rename(id, to: title) }
            // 남길 사본의 모든 파일이 자기 프로젝트 폴더 안에 있어야 입력 폴더를 지워도 열린다.
            let fixturePath = root.standardizedFileURL.path
            var relatives = record.sources.map(\.file)
            if let music = record.music { relatives.append(music.file) }
            if let output = record.outputFile { relatives.append(output) }
            keptFilesOutsideFixture = relatives.allSatisfy { relative in
                guard let url = store.fileURL(relative, id: id) else { return false }
                return FileManager.default.fileExists(atPath: url.path) && !url.standardizedFileURL.path.hasPrefix(fixturePath)
            }
            if run.saveKeptOutput == true, let output = record.outputFile, let url = store.fileURL(output, id: id),
               let saved = try? await SharedInboxStore().importDownloadedFile(at: url, originalFilename: TrailerNaming.outputFilename(mode: .trailer),
                                                                              contentTypeIdentifier: "public.mpeg-4") {
                savedOutput = "\(saved.originalFilename) \(saved.byteCount)"
            }
        }
        // 지운 프로젝트 폴더 정리는 저장소 작업 줄에서 끝난다.
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        let reloaded = TrailerProjectStore(root: store.root)
        let stillListed = deleted.filter { reloaded.records[UUID(uuidString: $0)!] != nil }
        if run.removeFixture == true && keptFilesOutsideFixture { try? FileManager.default.removeItem(at: root) }
        let summary: [String: Any] = ["deleted": deleted, "skipped": skipped, "stillListed": stillListed, "renamed": renamed, "savedOutput": savedOutput,
                                      "keptFilesOutsideFixture": keptFilesOutsideFixture,
                                      "remaining": reloaded.records.values.map { "\($0.id.uuidString) \($0.customTitle ?? "")" }.sorted(),
                                      "fixtureRemoved": !FileManager.default.fileExists(atPath: root.path)]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
            print("SHOTFIX_CLEANUP \(text)")
        }
        var problems: [String] = []
        if !stillListed.isEmpty { problems.append("삭제 후에도 남은 프로젝트: \(stillListed)") }
        if !keptFilesOutsideFixture { problems.append("남길 사본 파일이 입력 폴더에 의존: 입력 폴더를 지우지 않음") }
        if run.saveKeptOutput == true && savedOutput.isEmpty { problems.append("남길 사본 완성 영상을 폰하드에 저장하지 못함") }
        return problems
    }

    /// manifest의 sha256과 다른 입력 파일 이름(원본 54개 + 음악).
    private func mismatchedInputs() async -> [String] {
        let checks = manifest.sources.map { (input("raw/\($0.name)"), $0.sha256) } + [(input(manifest.music.file), manifest.music.sha256)]
        return await Task.detached {
            checks.compactMap { url, expected in (try? shotFixSHA256(url)) == expected ? nil : url.lastPathComponent }
        }.value
    }

    private func wait(_ what: String, timeout: TimeInterval, model: VideoTrailerModel, until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var nextLog = Date()
        while !done() {
            guard Date() < deadline else { throw ShotFixError.timeout(what) }
            if Date() >= nextLog {
                let export = model.exportProgress.map { String(format: "%.2f", $0) } ?? "-"
                let join = model.joinProgress.map { "\($0.completed)/\($0.total)" } ?? "-"
                log("\(what): \(model.status) export=\(export) join=\(join)")
                nextLog = Date().addingTimeInterval(15)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func stamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        return formatter.string(from: date)
    }

    private func fail(_ message: String) {
        failures.append(message)
        log("실패: \(message)")
    }

    private func noteDict(_ key: String, _ value: [String: Any]) { note(key, value) }

    /// 단계마다 report.json을 다시 써서, 중간에 멈춰도 거기까지의 사실이 남는다.
    private func note(_ key: String, _ value: Any) {
        report[key] = value
        guard JSONSerialization.isValidJSONObject(report),
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else {
            log("report 직렬화 불가: \(key)")
            return
        }
        try? data.write(to: out.appendingPathComponent("report.json"), options: .atomic)
    }

    private func log(_ line: String) {
        let text = Data("\(stamp()) \(line)\n".utf8)
        let url = out.appendingPathComponent("progress.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: text)
        } else {
            try? text.write(to: url)
        }
    }
}


// MARK: - 고급 편집 실제 렌더 증명 (합성 빨강/파랑 영상만 사용)

extension ShotFixHarness {
    fileprivate struct Probe { let seconds: Double; let video: Int; let audio: Int; let audioSeconds: Double }

    fileprivate func advancedProof(model: VideoTrailerModel, items: [RemoteFileItem], service: TrailerProjectMediaService) async throws {
        let fm = FileManager.default
        let frame = TrailerSceneEditor.frameMinimum
        func scene(_ id: Int, _ sourceID: Int, length: Double, start: Double = 0, _ adjust: (inout TrailerEditScene) -> Void = { _ in }) -> TrailerEditScene {
            var value = TrailerEditScene(id: id, sourceID: sourceID, start: start, length: length)
            value.manual = [.adjust]
            adjust(&value)
            return value
        }
        func render(_ name: String, _ scenes: [TrailerEditScene], music: TrailerMusicSelection? = nil,
                    voices: [TrailerVoiceoverTake] = []) async throws -> (url: URL, probe: Probe)? {
            model.start(items: items, service: service, mode: .trailer, generate: true, sourceOrder: model.sources.map(\.id), total: nil,
                        clipLength: 4, aspectRatio: nil, music: music, manualScenes: scenes, draftSources: model.sources,
                        revision: nil, introCard: nil, outroCard: nil, voiceovers: voices)
            try await wait("고급 렌더 \(name)", timeout: 600, model: model) { !model.isBusy }
            guard model.error == nil, let produced = model.outputURL, fm.fileExists(atPath: produced.path) else {
                fail("\(name): 렌더 실패 \(model.error ?? "출력 없음")")
                return nil
            }
            let target = out.appendingPathComponent("\(name).mp4")
            try? fm.removeItem(at: target)
            try fm.copyItem(at: produced, to: target)
            let asset = AVURLAsset(url: target)
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let audioRange = try await audio.first?.load(.timeRange)
            let probe = Probe(seconds: try await asset.load(.duration).seconds, video: video.count, audio: audio.count,
                              audioSeconds: audioRange?.duration.seconds ?? 0)
            return (target, probe)
        }
        func image(_ url: URL, _ seconds: Double) async throws -> CGImage {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.appliesPreferredTrackTransform = true
            return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        }
        /// 영역의 평균 색(0...255).
        func mean(_ cg: CGImage, _ region: CGRect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)) -> (r: Double, g: Double, b: Double) {
            let crop = CGRect(x: region.minX * Double(cg.width), y: region.minY * Double(cg.height),
                              width: region.width * Double(cg.width), height: region.height * Double(cg.height))
            guard let part = cg.cropping(to: crop) else { return (0, 0, 0) }
            var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(part, in: CGRect(x: 0, y: 0, width: 16, height: 16))
                return true
            }
            guard drawn else { return (0, 0, 0) }
            var sum = (0.0, 0.0, 0.0)
            for index in 0..<256 { sum.0 += Double(pixels[index * 4]); sum.1 += Double(pixels[index * 4 + 1]); sum.2 += Double(pixels[index * 4 + 2]) }
            return (sum.0 / 256, sum.1 / 256, sum.2 / 256)
        }
        /// 두 프레임이 아래쪽 영역에서 다른 화소의 비율(자막이 있고 없고를 본다).
        func difference(_ a: CGImage, _ b: CGImage, _ region: CGRect = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)) -> Double {
            func gray(_ cg: CGImage) -> [UInt8] {
                let crop = CGRect(x: region.minX * Double(cg.width), y: region.minY * Double(cg.height),
                                  width: region.width * Double(cg.width), height: region.height * Double(cg.height))
                var pixels = [UInt8](repeating: 0, count: 160 * 90)
                guard let part = cg.cropping(to: crop) else { return pixels }
                pixels.withUnsafeMutableBytes { buffer in
                    guard let context = CGContext(data: buffer.baseAddress, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 160,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                    context.interpolationQuality = .high
                    context.draw(part, in: CGRect(x: 0, y: 0, width: 160, height: 90))
                }
                return pixels
            }
            let left = gray(a), right = gray(b)
            let different = zip(left, right).filter { abs(Int($0) - Int($1)) > 40 }.count
            return Double(different) / Double(left.count)
        }
        /// 영역에서 흰 글자(밝은 회색 200 초과) 화소의 비율.
        func whiteShare(_ cg: CGImage, _ region: CGRect) -> Double {
            let crop = CGRect(x: region.minX * Double(cg.width), y: region.minY * Double(cg.height),
                              width: region.width * Double(cg.width), height: region.height * Double(cg.height))
            var pixels = [UInt8](repeating: 0, count: 320 * 180)
            guard let part = cg.cropping(to: crop) else { return 0 }
            pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 320,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                context.interpolationQuality = .high
                context.draw(part, in: CGRect(x: 0, y: 0, width: 320, height: 180))
            }
            return Double(pixels.filter { $0 > 200 }.count) / Double(pixels.count)
        }
        /// 출력 파일 소리의 RMS(0...1)를 `from...to`초에서 읽는다.
        func rms(_ url: URL, _ from: Double, _ to: Double) async throws -> Double {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return -1 }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44100])
            reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), duration: CMTime(seconds: to - from, preferredTimescale: 600))
            reader.add(output)
            guard reader.startReading() else { return -1 }
            var squares = 0.0, count = 0.0
            while let buffer = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                      let pointer else { continue }
                pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                    for index in 0..<(length / 2) { let value = Double(samples[index]) / 32768; squares += value * value; count += 1 }
                }
            }
            return count > 0 ? (squares / count).squareRoot() : 0
        }
        func previewSeconds(_ scenes: [TrailerEditScene], music: TrailerMusicSelection? = nil, captions: [String: TrailerCaption] = [:]) async -> Double {
            var segments = scenes.filter { !$0.excluded }.enumerated().map { index, edit in
                TrailerTimelineSegment(id: "s\(index)", kind: .clip, sceneID: edit.id, sourceID: edit.sourceID, start: edit.start, length: edit.length,
                                       muted: edit.muted, adjustments: edit.adjustments)
            }
            segments = TrailerAdvancedComposer.annotatingOverlaps(segments)
            let input = TrailerDraftPreviewInput(segments: segments, sources: model.sources, captions: captions, introCard: TrailerTitleCard(),
                                                 outroCard: TrailerTitleCard(), introBackground: nil, outroBackground: nil, bodyTypography: nil,
                                                 selectedSceneID: nil, music: music)
            let driver = TrailerAdvancedPreviewDriver()
            driver.attach(player: AVPlayer())
            await driver.prepare(input: input, key: UUID().uuidString, renderSize: CGSize(width: 1280, height: 720), introImage: nil, outroImage: nil, resumeAt: 0)
            if let failure = driver.failure { fail("미리보기 합성 실패: \(failure)") }
            let seconds = driver.duration
            driver.stop()
            return seconds
        }
        func record(_ name: String, _ values: [String: Any]) { noteDict("advanced.\(name)", values) }

        // A. 배속 2: 원본 10초 → 출력 5초
        let rate2 = [scene(1, 0, length: 10) { $0.adjustments = TrailerClipAdjustments(rate: 2) }]
        if let result = try await render("a-rate2", rate2) {
            record("a-rate2", ["seconds": result.probe.seconds, "expected": 5.0, "video": result.probe.video, "audio": result.probe.audio,
                               "planned": TrailerSceneEditor.outputBodyDuration(rate2)])
            if abs(result.probe.seconds - 5) > 0.12 || result.probe.video != 1 || result.probe.audio < 1 { fail("a-rate2: 길이/트랙 \(result.probe)") }
        }

        // B. 5초 + 5초, 1초 디졸브 → 9초, 가운데 프레임은 빨강과 파랑이 섞인다
        let dissolve = [scene(1, 0, length: 5) { $0.adjustments = TrailerClipAdjustments(transition: TrailerTransition(dissolveDuration: 1)) },
                        scene(2, 1, length: 5)]
        if let result = try await render("b-dissolve", dissolve) {
            let early = mean(try await image(result.url, 2)), mixed = mean(try await image(result.url, 4.5)), late = mean(try await image(result.url, 7))
            let preview = await previewSeconds(dissolve)
            record("b-dissolve", ["seconds": result.probe.seconds, "expected": 9.0, "previewSeconds": preview,
                                  "frame2": [early.r, early.g, early.b], "frame4.5": [mixed.r, mixed.g, mixed.b], "frame7": [late.r, late.g, late.b]])
            if abs(result.probe.seconds - 9) > 0.12 { fail("b-dissolve: 길이 \(result.probe.seconds)") }
            if !(early.r > 150 && early.b < 80) || !(late.b > 150 && late.r < 80) { fail("b-dissolve: 양끝 색 \(early) \(late)") }
            if !(mixed.r > 60 && mixed.b > 60 && mixed.r < 190 && mixed.b < 190) { fail("b-dissolve: 가운데 프레임이 섞이지 않음 \(mixed)") }
            if abs(preview - result.probe.seconds) > 0.12 { fail("b-dissolve: 미리보기 \(preview) != 내보내기 \(result.probe.seconds)") }
        }

        // C. 시간 큐(원본 2~3초, 배속 2 → 출력 1~1.5초)와 정적 수동 자막. 큐는 일부러 다른 위치(아래 가운데)에 두어 둘 다 읽히는지 본다.
        let cueStyle = TrailerCaption(text: "", column: 2, row: 4)
        let cue = TrailerTimedCaptionCue(sourceID: 0, sourceStart: 2, sourceEnd: 3, text: "큐 자막", style: cueStyle, origin: .manual, manuallyEdited: true)
        let cued = [scene(1, 0, length: 4) {
            $0.adjustments = TrailerClipAdjustments(rate: 2, cues: [cue])
            $0.caption = TrailerCaption(text: "고정 자막")
            $0.manual.insert(.caption)
        }]
        if let result = try await render("c-cue", cued) {
            let before = try await image(result.url, 0.25), inside = try await image(result.url, 1.25), after = try await image(result.url, 1.75)
            let staticArea = CGRect(x: 0.05, y: 0.05, width: 0.4, height: 0.2), cueArea = CGRect(x: 0.2, y: 0.75, width: 0.6, height: 0.23)
            let preview = await previewSeconds(cued, captions: ["s0": TrailerCaption(text: "고정 자막")])
            let staticBefore = whiteShare(before, staticArea), staticInside = whiteShare(inside, staticArea), staticAfter = whiteShare(after, staticArea)
            let cueBefore = whiteShare(before, cueArea), cueInside = whiteShare(inside, cueArea), cueAfter = whiteShare(after, cueArea)
            record("c-cue", ["seconds": result.probe.seconds, "expected": 2.0, "previewSeconds": preview,
                             "staticText(before,inside,after)": [staticBefore, staticInside, staticAfter],
                             "cueText(before,inside,after)": [cueBefore, cueInside, cueAfter]])
            if abs(result.probe.seconds - 2) > frame + 0.02 { fail("c-cue: 길이 \(result.probe.seconds)") }
            if !(staticBefore > 0.003 && staticInside > 0.003 && staticAfter > 0.003) { fail("c-cue: 고정 자막이 큐 구간 안팎에서 계속 보이지 않음 \(staticBefore) \(staticInside) \(staticAfter)") }
            if !(cueInside > 0.003 && cueBefore < 0.0005 && cueAfter < 0.0005) { fail("c-cue: 큐가 출력 1~1.5초에만 보여야 함 \(cueBefore) \(cueInside) \(cueAfter)") }
            if abs(preview - result.probe.seconds) > frame + 0.02 { fail("c-cue: 미리보기 \(preview) != 내보내기 \(result.probe.seconds)") }
        }

        // D. 색상(채도 0)과 키프레임(불투명도 1 → 0): 값이 바뀌면 프레임이 바뀐다
        let look = [scene(1, 0, length: 3) { $0.adjustments = TrailerClipAdjustments(color: TrailerColorAdjustment(saturation: 0)) },
                    scene(2, 1, length: 3) {
                        $0.adjustments = TrailerClipAdjustments(keyframes: [TrailerTransformKeyframe(sourceTime: 0, opacity: 1),
                                                                            TrailerTransformKeyframe(sourceTime: 3, opacity: 0)])
                    }]
        if let result = try await render("d-color-keyframe", look) {
            let gray = mean(try await image(result.url, 1.5)), bright = mean(try await image(result.url, 3.2)), dim = mean(try await image(result.url, 5.8))
            record("d-color-keyframe", ["seconds": result.probe.seconds, "expected": 6.0, "grayFrame": [gray.r, gray.g, gray.b],
                                        "keyframeStart": [bright.r, bright.g, bright.b], "keyframeEnd": [dim.r, dim.g, dim.b]])
            if abs(result.probe.seconds - 6) > 0.12 { fail("d: 길이 \(result.probe.seconds)") }
            if !(abs(gray.r - gray.g) < 25 && abs(gray.g - gray.b) < 25 && gray.r > 20) { fail("d: 채도 0 프레임이 회색이 아님 \(gray)") }
            if !(bright.b > 120 && dim.b < bright.b * 0.5) { fail("d: 키프레임 불투명도 변화 없음 \(bright) → \(dim)") }
        }

        // E. 독립 음성 해설 1레인: 원본 소리를 끄면 해설 구간만 들리고, 켜면 원본과 함께 섞인다
        let voiceID = UUID()
        let staged = try model.stageVoiceover(copying: root.appendingPathComponent("voice/voice.wav"), id: voiceID)
        let take = TrailerVoiceoverTake(stableID: voiceID, relativeFile: staged, outputStart: 1, sourceIn: 0, sourceOut: 2, volume: 1)
        let muted = [scene(1, 0, length: 4) { $0.muted = true; $0.manual.insert(.audio) }]
        if let result = try await render("e-voice-muted", muted, voices: [take]) {
            let silent = try await rms(result.url, 0.1, 0.8), voiced = try await rms(result.url, 1.2, 2.8), tail = try await rms(result.url, 3.2, 3.8)
            record("e-voice-muted", ["seconds": result.probe.seconds, "rmsBefore": silent, "rmsVoice": voiced, "rmsAfter": tail])
            if abs(result.probe.seconds - 4) > 0.12 { fail("e-muted: 길이 \(result.probe.seconds)") }
            if !(voiced > 0.02 && silent < 0.004 && tail < 0.004) { fail("e-muted: 해설 구간만 들려야 함 \(silent) \(voiced) \(tail)") }
        }
        let open = [scene(1, 0, length: 4)]
        if let result = try await render("e-voice-mixed", open, voices: [take]) {
            let original = try await rms(result.url, 0.1, 0.8), mixed = try await rms(result.url, 1.2, 2.8)
            record("e-voice-mixed", ["seconds": result.probe.seconds, "rmsOriginalOnly": original, "rmsOriginalPlusVoice": mixed])
            if !(original > 0.02 && mixed > original * 1.15) { fail("e-mixed: 원본과 해설이 섞이지 않음 \(original) \(mixed)") }
        }
        model.releaseVoiceover(voiceID)

        // F. 짧은 목표와 큰 디졸브 재클램프: 실제 출력이 요청의 한 프레임 안
        let clamp = [scene(1, 0, length: 10) { $0.adjustments = TrailerClipAdjustments(transition: TrailerTransition(dissolveDuration: 50)) },
                     scene(2, 1, length: 10) { $0.adjustments = TrailerClipAdjustments(rate: 1.5) }]
        for target in [3.0, 0.5] {
            var fitted = clamp
            guard let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &fitted, sources: model.sources, bodyTarget: target) else { fail("f: 목표 \(target) 맞춤 실패"); continue }
            let planned = TrailerSceneEditor.outputBodyDuration(fitted)
            let name = "f-target-\(target)"
            record("\(name)-plan", ["target": target, "fitTotal": fit.total, "plannedOutput": planned, "starts": fitted.map(\.start), "sceneLengths": fitted.map(\.length),
                                    "excluded": fitted.map(\.excluded), "rates": fitted.map { $0.adjustments?.rate ?? 1 },
                                    "dissolves": fitted.map { $0.adjustments?.transition?.dissolveDuration ?? 0 }])
            guard let result = try await render(name, fitted) else { continue }
            record(name, ["target": target, "fitTotal": fit.total, "plannedOutput": planned, "seconds": result.probe.seconds,
                          "sceneLengths": fitted.map(\.length), "excluded": fitted.map(\.excluded)])
            if abs(planned - target) > frame + 1e-6 { fail("\(name): 계획 \(planned) != 목표 \(target)") }
            if abs(result.probe.seconds - planned) > frame + 0.04 { fail("\(name): 실제 \(result.probe.seconds) != 계획 \(planned)") }
        }

        // F2. 큰 디졸브가 이웃 클립을 거의 덮는 경우도 실제로 내보내진다(배속 유무)
        let swallow: [(String, [TrailerEditScene])] = [
            ("f2-swallow-plain", [scene(1, 0, length: 3) { $0.adjustments = TrailerClipAdjustments(transition: TrailerTransition(dissolveDuration: 50)) }, scene(2, 1, length: 2)]),
            ("f2-swallow-rate", [scene(1, 0, length: 3) { $0.adjustments = TrailerClipAdjustments(transition: TrailerTransition(dissolveDuration: 50)) },
                                 scene(2, 1, length: 2) { $0.adjustments = TrailerClipAdjustments(rate: 1.5) }]),
            ("f2-dissolve-rate", [scene(1, 0, length: 3) { $0.adjustments = TrailerClipAdjustments(transition: TrailerTransition(dissolveDuration: 1)) },
                                  scene(2, 1, length: 2) { $0.adjustments = TrailerClipAdjustments(rate: 1.5) }])]
        for (name, list) in swallow {
            let planned = TrailerSceneEditor.outputBodyDuration(list)
            guard let result = try await render(name, list) else { continue }
            record(name, ["planned": planned, "seconds": result.probe.seconds])
            if abs(result.probe.seconds - planned) > frame + 0.04 { fail("\(name): 실제 \(result.probe.seconds) != 계획 \(planned)") }
        }

        // G. 0.25배속에서 출력 한 프레임
        var tiny = [scene(1, 0, length: 8) { $0.adjustments = TrailerClipAdjustments(rate: 0.25) }]
        if TrailerSceneEditor.fitScenesToBudget(scenes: &tiny, sources: model.sources, bodyTarget: frame) != nil,
           let result = try await render("g-tiny-one-frame", tiny) {
            record("g-tiny-one-frame", ["seconds": result.probe.seconds, "sourceLength": tiny[0].length, "video": result.probe.video])
            if result.probe.video != 1 || result.probe.seconds < 0.02 || result.probe.seconds > frame + 0.1 { fail("g: 한 프레임 출력 이상 \(result.probe)") }
        } else { fail("g: 한 프레임 목표 맞춤/렌더 실패") }

        // H. 음악(3초)을 영상 5초에 반복으로 깐다: 영상·소리·미리보기 길이가 같다
        let musicURL = input(manifest.music.file)
        let musicSelection = TrailerMusicSelection(recordID: UUID(), name: manifest.music.name, url: musicURL,
                                                   duration: try await TrailerMusic.usableDuration(of: musicURL), policy: .loopMusic, fitCount: 1)
        let withMusic = [scene(1, 0, length: 5)]
        if let result = try await render("h-music", withMusic, music: musicSelection) {
            let preview = await previewSeconds(withMusic, music: musicSelection)
            record("h-music", ["seconds": result.probe.seconds, "audioSeconds": result.probe.audioSeconds, "previewSeconds": preview])
            if abs(result.probe.seconds - 5) > 0.12 || abs(result.probe.audioSeconds - result.probe.seconds) > 0.12
                || abs(preview - result.probe.seconds) > 0.12 { fail("h-music: 길이 불일치 \(result.probe) 미리보기 \(preview)") }
        }

        // J/K. 읽을 수 없게 망가진 원본(이 하네스가 받은 작업 사본만 덮어쓴다): 직접 편집한 장면은 조용히 빠지지 않고 오류, 순수 자동 장면만 건너뛴다.
        if let damaged = model.sources.first(where: { $0.id == 1 }) {
            try Data(repeating: 0, count: 2048).write(to: damaged.url)
            let skippedBefore = model.skippedCount
            func attempt(_ scenes: [TrailerEditScene]) async throws -> String? {
                model.start(items: items, service: service, mode: .trailer, generate: true, sourceOrder: model.sources.map(\.id), total: nil,
                            clipLength: 4, aspectRatio: nil, music: nil, manualScenes: scenes, draftSources: model.sources,
                            revision: nil, introCard: nil, outroCard: nil, voiceovers: [])
                try await wait("손상 원본", timeout: 600, model: model) { !model.isBusy }
                return model.error
            }
            let manualBlue = [scene(1, 0, length: 3), scene(2, 1, length: 3)]
            let manualError = try await attempt(manualBlue)
            record("j-damaged-manual", ["error": manualError ?? "nil", "outputURLIsNil": model.outputURL == nil])
            if manualError == nil { fail("j: 직접 편집한 장면의 원본이 손상됐는데 성공으로 끝남") }
            let advancedError = try await attempt([scene(1, 0, length: 3), scene(2, 1, length: 3) { $0.adjustments = TrailerClipAdjustments(rate: 1.25) }])
            record("j2-damaged-manual-advanced", ["error": advancedError ?? "nil"])
            if advancedError == nil { fail("j2: 고급 편집 경로에서 직접 편집한 장면의 원본이 손상됐는데 성공으로 끝남") }
            var autoBlue = scene(2, 1, length: 3)
            autoBlue.manual = []
            let autoError = try await attempt([scene(1, 0, length: 3), autoBlue])
            let autoSeconds = model.outputURL.map { (try? AVURLAsset(url: $0).duration.seconds) ?? -1 } ?? -1
            record("k-damaged-auto", ["error": autoError ?? "nil", "skipped": model.skippedCount - skippedBefore, "seconds": autoSeconds])
            if autoError != nil || abs(autoSeconds - 3) > 0.12 { fail("k: 순수 자동 장면은 건너뛰고 나머지 3초가 나와야 함 \(autoError ?? "-") \(autoSeconds)") }
        } else { fail("j: 손상시킬 작업 사본을 찾지 못함") }
    }
}
