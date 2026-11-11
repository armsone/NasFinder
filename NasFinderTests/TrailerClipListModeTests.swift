import XCTest
@testable import NasFinder

final class TrailerClipListModeTests: XCTestCase {
    func testTitlesAndPersistedRawValuesAreStable() {
        XCTAssertEqual(TrailerClipListMode.allCases.map(\.title), ["자세히", "썸네일", "포스터"])
        XCTAssertEqual(TrailerClipListMode.allCases.map(\.rawValue), ["detail", "thumbnail", "poster"])
        XCTAssertEqual(TrailerClipListMode(rawValue: "poster"), .poster)
        XCTAssertNil(TrailerClipListMode(rawValue: "unknown"))
    }

    func testOnlyGridModesUseFixedInspector() {
        XCTAssertFalse(TrailerClipListMode.detail.isGrid)
        XCTAssertTrue(TrailerClipListMode.thumbnail.isGrid)
        XCTAssertTrue(TrailerClipListMode.poster.isGrid)
    }

    // MARK: - 자동화 보호 (합성 데이터만 사용)

    private let dummyURL = URL(fileURLWithPath: "/dummy")

    private func videoSource(id: Int, duration: Double = 20) -> VideoTrailerSource {
        let analysis = AudioAnalysisResult(waveform: [], peakTime: 0, peakTimes: [], audioAvailability: .unknown, highlightSource: .fallback)
        return VideoTrailerSource(id: id, name: "v\(id)", url: dummyURL,
                                  plan: VideoTrailerPlan(analysis: analysis, duration: duration), isImage: false)
    }

    private func photoSource(id: Int) -> VideoTrailerSource {
        let analysis = AudioAnalysisResult(waveform: [], peakTime: 0, peakTimes: [], audioAvailability: .unknown, highlightSource: .fallback)
        return VideoTrailerSource(id: id, name: "p\(id)", url: dummyURL,
                                  plan: VideoTrailerPlan(analysis: analysis, duration: 4), isImage: true,
                                  imageDurationRatio: 0.55, imageDurationPolicyVersion: 2)
    }

    /// PhotoSelectionEngineTests와 같은 합성 분석: 20칸 파형에서 `peak` 시각이 속한 칸만 크고 나머지는 작다.
    /// 큰 소리 피크라 `rankedActionPeaks`에 올라 실제 피크 경로(중요도·피크 중심 좁히기)를 탄다.
    private func spikeSource(id: Int, duration: Double = 30, peak: Double) -> VideoTrailerSource {
        var wave = [Double](repeating: 0.1, count: 20)
        wave[min(19, Int(peak / duration * 20))] = 1.0
        let analysis = AudioAnalysisResult(waveform: wave, peakTime: peak, peakTimes: [peak],
                                           audioAvailability: .present, highlightSource: .audio)
        return VideoTrailerSource(id: id, name: "s\(id)", url: dummyURL,
                                  plan: VideoTrailerPlan(analysis: analysis, duration: duration), isImage: false)
    }

    private func photoScene(id: Int, sourceID: Int, length: Double, locked: Bool) -> TrailerEditScene {
        var scene = TrailerEditScene(id: id, sourceID: sourceID, start: 0, length: length)
        scene.automationProtected = locked
        return scene
    }

    func testLegacyScenesReadAsProtectedAndProtectionRoundTrips() throws {
        let legacy = Data(#"{"id":1,"sourceID":2,"start":1.5,"length":3.0}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(TrailerEditScene.self, from: legacy).automationProtected,
                      "보호 정보가 없는 이전 저장본은 안전하게 모두 보호된 것으로 읽습니다.")
        XCTAssertFalse(TrailerEditScene(id: 1, sourceID: 2, start: 0, length: 1).automationProtected, "새 장면은 보호되지 않습니다.")
        XCTAssertTrue(TrailerEditScene(id: 1, sourceID: 2, start: 0, length: 1).manual.isEmpty, "새 장면은 직접 편집 표시가 없습니다.")
        let decodedLegacy = try JSONDecoder().decode(TrailerEditScene.self, from: legacy)
        XCTAssertTrue(decodedLegacy.manual.isEmpty)
        XCTAssertTrue(decodedLegacy.timingProtected && decodedLegacy.exclusionProtected && decodedLegacy.hasManualContent,
                      "이전 저장본은 모든 필드가 보호된 것으로 읽습니다.")
        let masks: [TrailerManualFields] = [[], [.caption], [.timing, .order], [.audio, .framing, .exclusion], .all]
        for value in [false, true] {
            for mask in masks {
                var scene = TrailerEditScene(id: 7, sourceID: 2, start: 2, length: 3, caption: TrailerCaption(text: "자막"))
                scene.automationProtected = value
                scene.manual = mask
                let again = try JSONDecoder().decode(TrailerEditScene.self, from: JSONEncoder().encode(scene))
                XCTAssertEqual(again, scene)
                XCTAssertEqual(again.automationProtected, value)
                XCTAssertEqual(again.manual, mask, "저장·복원은 필드 표시를 정확히 보존합니다.")
            }
        }
        // 되돌리기 항목은 장면 값을 통째로 비교하므로 표시만 달라도 다른 상태이고, 복원하면 표시도 그대로 돌아온다.
        let plain = [TrailerEditScene(id: 1, sourceID: 2, start: 0, length: 1)]
        var marked = plain
        TrailerSceneEditor.update(1, in: &marked) { $0.caption = TrailerCaption(text: "x") }
        XCTAssertNotEqual(plain, marked)
        let history = [plain, marked]
        XCTAssertEqual(history[1].first?.manual, [.caption])
        XCTAssertEqual(history[0].first?.manual, [])
    }

    func testGenericUpdateMarksOnlyTheFieldsThatActuallyChanged() {
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 2, length: 6)]
        TrailerSceneEditor.update(1, in: &scenes) { $0.caption = $0.caption }
        XCTAssertTrue(scenes[0].manual.isEmpty, "값이 그대로면 아무것도 표시하지 않습니다.")
        TrailerSceneEditor.update(1, in: &scenes) { $0.caption = TrailerCaption(text: "자막") }
        XCTAssertEqual(scenes[0].manual, [.caption])
        TrailerSceneEditor.update(1, in: &scenes) { $0.volume = 0.3 }
        XCTAssertEqual(scenes[0].manual, [.caption, .audio])
        TrailerSceneEditor.update(1, in: &scenes) { $0.offsetX = 0.5 }
        XCTAssertEqual(scenes[0].manual, [.caption, .audio, .framing])
        XCTAssertFalse(scenes[0].automationProtected, "일반 편집은 전체 보호를 켜지 않습니다.")
        XCTAssertFalse(scenes[0].timingProtected, "자막·소리·화면 구성만 고치면 시간은 계속 자동입니다.")
        TrailerSceneEditor.update(1, in: &scenes) { $0.length = 5 }
        XCTAssertTrue(scenes[0].manual.contains(.timing) && scenes[0].timingProtected)
        TrailerSceneEditor.update(1, in: &scenes) { $0.excluded = true }
        XCTAssertTrue(scenes[0].manual.contains(.exclusion) && scenes[0].exclusionProtected)
    }

    func testRecommendationOnlyChangesSelectedUnprotectedScenes() {
        let sources = [photoSource(id: 1), photoSource(id: 2)]
        let original = [photoScene(id: 1, sourceID: 1, length: 9, locked: false),
                        photoScene(id: 2, sourceID: 2, length: 9, locked: false),
                        photoScene(id: 3, sourceID: 1, length: 9, locked: true)]
        var scenes = original
        XCTAssertEqual(TrailerSceneEditor.automationCounts(ids: [1, 3], in: scenes).eligible, 1)
        XCTAssertEqual(TrailerSceneEditor.automationCounts(ids: [1, 3], in: scenes).protected, 1)
        let changed = TrailerSceneEditor.refreshAutomaticScenes(ids: [1, 3], sources: sources, clipLength: 4, in: &scenes)
        XCTAssertEqual(changed, 1)
        XCTAssertNotEqual(scenes[0].length, 9, "고른 보호되지 않은 장면은 추천 길이로 바뀝니다.")
        XCTAssertFalse(scenes[0].automationProtected, "추천은 장면을 잠그지 않습니다.")
        XCTAssertEqual(scenes[1], original[1], "고르지 않은 장면은 보호되지 않았어도 바뀌지 않습니다.")
        XCTAssertEqual(scenes[2], original[2], "보호된 장면은 고르더라도 바뀌지 않습니다.")
        XCTAssertEqual(scenes.map(\.id), original.map(\.id), "추천은 순서를 바꾸지 않습니다.")
        // 보호된 장면만 고르면 아무것도 하지 않는다.
        var onlyLocked = original
        XCTAssertEqual(TrailerSceneEditor.refreshAutomaticScenes(ids: [3], sources: sources, clipLength: 4, in: &onlyLocked), 0)
        XCTAssertEqual(onlyLocked, original)
    }

    /// 자동 장면의 동작 구간이 추천 길이보다 길어도 목표 길이는 그대로 두고 가장 좋은 피크 중심으로 좁힌다. 목록과 계획이 같은 시간을 가리킨다.
    func testRecommendationKeepsTheTargetLengthAndNarrowsLongActionToItsPeak() {
        let source = spikeSource(id: 1, peak: 5.5)
        var content = TrailerEditScene(id: 1, sourceID: 1, start: 20, length: 4)
        content.caption = TrailerCaption(text: "직접 자막")
        content.volume = 0.3
        content.manual = [.caption, .audio]
        var fixed = TrailerEditScene(id: 2, sourceID: 1, start: 12, length: 3)
        fixed.manual = [.timing]
        let outside = TrailerEditScene(id: 3, sourceID: 1, start: 20, length: 8)
        var scenes = [content, fixed, outside]
        let expectedFixed = scenes[1], expectedOutside = scenes[2]
        XCTAssertEqual(TrailerSceneEditor.refreshAutomaticScenes(ids: [1, 2], sources: [source], clipLength: 4, in: &scenes), 1)
        let scene = scenes[0]
        XCTAssertEqual(scene.length, 4, accuracy: 1e-9, "추천 목표 길이를 보호 동작 구간(6초)에 맞춰 늘리지 않습니다.")
        let a = scene.actionStart ?? -1, b = scene.actionEnd ?? -1
        XCTAssertLessThanOrEqual(scene.start, 5.5, "가장 중요한 피크가 실제 창 안에 있습니다.")
        XCTAssertGreaterThanOrEqual(scene.start + scene.length, 5.5)
        XCTAssertGreaterThanOrEqual(a, scene.start - 1e-9, "동작 구간이 실제 창 안입니다.")
        XCTAssertLessThanOrEqual(b, scene.start + scene.length + 1e-9)
        XCTAssertGreaterThanOrEqual(scene.start, 0)
        XCTAssertLessThanOrEqual(scene.start + scene.length, source.duration)
        let plan = TrailerPreparedPlan.manual(scenes, sources: [source])
        XCTAssertEqual(plan.first?.length ?? 0, scene.length, accuracy: 1e-9, "계획 길이가 목록 길이와 같습니다.")
        XCTAssertEqual(plan.first?.start ?? -1, scene.start, accuracy: 1e-9)
        XCTAssertEqual(scene.caption?.text, "직접 자막", "직접 고친 자막·소리는 그대로입니다.")
        XCTAssertEqual(scene.volume, 0.3)
        XCTAssertEqual(scene.manual, [.caption, .audio])
        XCTAssertEqual(scenes[1], expectedFixed, "시간이 고정된 장면은 그대로입니다.")
        XCTAssertEqual(scenes[2], expectedOutside, "고르지 않은 장면은 그대로입니다.")
    }

    /// 동작 구간이 추천 길이보다 짧아도 요청 창 밖에 걸치면 같은 길이로 창을 옮겨 동작 구간을 담는다. 목록과 계획이 같은 시간을 가리킨다.
    func testRecommendationShiftsTheWindowToContainAShortActionWithoutChangingLength() {
        let source = spikeSource(id: 1, peak: 12)
        let proposal = source.plan.proposal(total: 6.5, clipLength: 6.5)[0]
        let requested = source.plan.actionWindow(start: proposal.start, length: proposal.length)
        XCTAssertEqual(requested.length, 6.5, accuracy: 1e-9, "동작 구간(6초)이 추천 길이보다 짧아 요청 창은 그대로입니다.")
        XCTAssertGreaterThan(requested.action.end, requested.start + requested.length + 1e-9, "시작 상태: 동작 구간이 요청 창 밖에 걸칩니다.")
        var content = TrailerEditScene(id: 1, sourceID: 1, start: 20, length: 6.5)
        content.caption = TrailerCaption(text: "직접 자막")
        content.manual = [.caption]
        let outside = TrailerEditScene(id: 2, sourceID: 1, start: 20, length: 8)
        var scenes = [content, outside]
        let expectedOutside = scenes[1]
        XCTAssertEqual(TrailerSceneEditor.refreshAutomaticScenes(ids: [1], sources: [source], clipLength: 6.5, in: &scenes), 1)
        let scene = scenes[0]
        XCTAssertEqual(scene.length, 6.5, accuracy: 1e-9, "창을 옮길 뿐 목표 길이는 그대로입니다.")
        let a = scene.actionStart ?? -1, b = scene.actionEnd ?? -1
        XCTAssertEqual(a, requested.action.start, accuracy: 1e-9)
        XCTAssertEqual(b, requested.action.end, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(a, scene.start - 1e-9, "동작 구간이 실제 창 안입니다.")
        XCTAssertLessThanOrEqual(b, scene.start + scene.length + 1e-9)
        XCTAssertLessThanOrEqual(scene.start, 12)
        XCTAssertGreaterThanOrEqual(scene.start + scene.length, 12, "피크도 창 안입니다.")
        let plan = TrailerPreparedPlan.manual(scenes, sources: [source])
        XCTAssertEqual(plan.first?.length ?? 0, scene.length, accuracy: 1e-9)
        XCTAssertEqual(plan.first?.start ?? -1, scene.start, accuracy: 1e-9, "계획이 장면을 다시 밀거나 늘리지 않습니다.")
        XCTAssertEqual(scene.caption?.text, "직접 자막")
        XCTAssertEqual(scene.manual, [.caption])
        XCTAssertEqual(scenes[1], expectedOutside, "고르지 않은 장면은 그대로입니다.")
    }

    func testSelectionFreezeKeepsUnselectedScenesWhileFitting() {
        let sources = [photoSource(id: 1)]
        var scenes = (1...3).map { photoScene(id: $0, sourceID: 1, length: 5, locked: false) }
        TrailerSceneEditor.freezing(except: [1], in: &scenes) { list in
            _ = TrailerSceneEditor.fitScenesToBudget(scenes: &list, sources: sources, bodyTarget: 12)
        }
        XCTAssertEqual(scenes[0].length, 2, accuracy: 0.01, "고른 장면이 남은 예산을 받습니다.")
        XCTAssertEqual(scenes[1].length, 5, accuracy: 1e-9)
        XCTAssertEqual(scenes[2].length, 5, accuracy: 1e-9)
        XCTAssertTrue(scenes.allSatisfy { !$0.automationProtected && !$0.excluded }, "임시 고정은 보호 표시를 남기지 않습니다.")
        XCTAssertTrue(scenes.allSatisfy { $0.manual.isEmpty }, "임시 고정은 필드 표시도 남기지 않습니다.")
        // 고르지 않은 장면은 값과 표시가 통째로 그대로여야 한다(자막·순서 표시가 있는 장면도).
        var edited = (1...3).map { photoScene(id: $0, sourceID: 1, length: 5, locked: false) }
        TrailerSceneEditor.update(2, in: &edited) { $0.caption = TrailerCaption(text: "그대로") }
        edited[2].manual.insert(.order)
        let untouched = [edited[1], edited[2]]
        TrailerSceneEditor.freezing(except: [1], in: &edited) { list in
            _ = TrailerSceneEditor.fitScenesToBudget(scenes: &list, sources: sources, bodyTarget: 6)
            for index in list.indices { list[index].manual.insert(.timing) }   // 본문이 표시를 건드려도 밖으로 새지 않는다.
        }
        XCTAssertEqual([edited[1], edited[2]], untouched, "고르지 않은 장면은 값·표시가 모두 그대로입니다.")
    }

    func testProtectedScenesKeepTheirLengthWhenBudgetIsShorter() {
        let sources = [photoSource(id: 1)]
        var scenes = [photoScene(id: 1, sourceID: 1, length: 5, locked: true),
                      photoScene(id: 2, sourceID: 1, length: 5, locked: true),
                      photoScene(id: 3, sourceID: 1, length: 5, locked: false)]
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 4)
        XCTAssertNotNil(fit, "짧은 목표는 실패가 아니라 실제 길이로 맞춰집니다.")
        XCTAssertEqual(fit?.total ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(scenes[0].length, 5, accuracy: 1e-9)
        XCTAssertEqual(scenes[1].length, 5, accuracy: 1e-9)
        XCTAssertFalse(scenes[0].excluded || scenes[1].excluded || scenes[0].budgetExcluded || scenes[1].budgetExcluded)
        XCTAssertTrue(scenes[2].excluded && scenes[2].budgetExcluded, "보호되지 않은 장면만 길이 맞춤으로 빠집니다.")
        XCTAssertEqual(TrailerSceneEditor.effectiveFitDuration(fitted: 4, scenes: scenes, cardsDuration: 2), 12, accuracy: 0.01)
        // 목표가 커지면 빠졌던 장면만 돌아오고 보호 장면은 그대로다.
        _ = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 40)
        XCTAssertFalse(scenes[2].excluded)
        XCTAssertEqual(scenes[0].length, 5, accuracy: 1e-9)
        // 모두 보호된 목록은 어떤 목표에서도 그대로다.
        var allLocked = (1...3).map { photoScene(id: $0, sourceID: 1, length: 4, locked: true) }
        let before = allLocked
        _ = TrailerSceneEditor.fitScenesToBudget(scenes: &allLocked, sources: sources, bodyTarget: 30)
        XCTAssertEqual(allLocked, before)
        let music = TrailerSceneEditor.fitScenesToMusic(scenes: &allLocked, sources: sources, musicDuration: 4, startCount: 1,
                                                        cardsDuration: 0, maximumRepeats: 600)
        XCTAssertTrue(music.fits)
        XCTAssertEqual(music.total, 12, accuracy: 0.01)
        XCTAssertEqual(allLocked, before)
    }

    func testProtectedScenesAreTheFinalPlanForPreviewAndExport() {
        let sources = [videoSource(id: 1), photoSource(id: 2)]
        var video = TrailerEditScene(id: 1, sourceID: 1, start: 2, length: 6)
        video.automationProtected = true
        let photo = photoScene(id: 2, sourceID: 2, length: 5, locked: true)
        let music = TrailerMusicSelection(recordID: UUID(), name: "m", url: dummyURL, duration: 4, policy: .fitMusic)
        let kept = TrailerPreparedPlan.scenes(mode: .trailer, sources: sources, total: 4, clipLength: 4, music: music,
                                              manual: [video, photo], cardsDuration: 0)
        XCTAssertEqual(kept.map(\.length), [6, 5], "보호 장면은 음악 길이에 맞춰 잘리거나 반복되지 않습니다.")
        XCTAssertEqual(kept.first?.start ?? -1, 2, accuracy: 1e-9)
        video.automationProtected = false
        let refit = TrailerPreparedPlan.scenes(mode: .trailer, sources: sources, total: 4, clipLength: 4, music: music,
                                               manual: [video, photoScene(id: 2, sourceID: 2, length: 5, locked: false)], cardsDuration: 0)
        XCTAssertEqual(refit.reduce(0) { $0 + $1.length }, 4, accuracy: 0.01, "보호되지 않은 목록은 기존대로 음악 길이에 맞춰집니다.")
    }

    func testSplitConservesTimeIdentityAndMetadata() {
        let source = videoSource(id: 1)
        var video = TrailerEditScene(id: 5, sourceID: 1, start: 4, length: 6, muted: true, fitsFrame: true, volume: 0.4,
                                     offsetX: 0.2, offsetY: -0.1, caption: TrailerCaption(text: "자막"))
        video.automationProtected = false
        var scenes = [video, photoScene(id: 6, sourceID: 2, length: 3, locked: false)]
        var nextID = 6
        let newID = TrailerSceneEditor.split(5, atLocalTime: 2.5, source: source, in: &scenes, nextID: &nextID)
        XCTAssertNotNil(newID)
        XCTAssertEqual(scenes.count, 3)
        XCTAssertEqual(Set(scenes.map(\.id)).count, 3, "새 id는 기존 id와 겹치지 않습니다.")
        XCTAssertEqual(scenes[0].id, 5)
        XCTAssertEqual(scenes[1].id, newID)
        XCTAssertEqual(scenes[0].length + scenes[1].length, 6, accuracy: 1e-9, "나눈 두 조각의 길이 합은 그대로입니다.")
        XCTAssertEqual(scenes[1].start, scenes[0].start + scenes[0].length, accuracy: 1e-9, "두 조각은 원본에서 이어집니다.")
        for piece in [scenes[0], scenes[1]] {
            XCTAssertEqual(piece.sourceID, 1)
            XCTAssertTrue(piece.muted && piece.fitsFrame)
            XCTAssertEqual(piece.volume, 0.4, accuracy: 1e-9)
            XCTAssertEqual(piece.offsetX, 0.2, accuracy: 1e-9)
            XCTAssertEqual(piece.caption?.text, "자막")
            XCTAssertTrue(piece.timingProtected && piece.manual.contains(.timing), "나눈 두 조각은 시간이 직접 정해진 것으로 표시됩니다.")
            XCTAssertFalse(piece.automationProtected, "나누기는 전체 보호를 켜지 않습니다.")
            XCTAssertFalse(piece.manual.contains(.caption) || piece.manual.contains(.audio), "원래 장면에 없던 자막·소리 표시를 만들지 않습니다.")
        }
        XCTAssertTrue(scenes[1].manual.isSuperset(of: [.order, .exclusion]), "새 조각은 포함·순서 의도를 갖습니다.")
        XCTAssertGreaterThan(nextID, newID ?? 0)
        // 경계에 너무 가깝거나 소스가 다르면 거절하고 아무것도 바꾸지 않는다.
        let snapshot = scenes
        var untouchedID = nextID
        XCTAssertNil(TrailerSceneEditor.split(5, atLocalTime: 0.05, source: source, in: &scenes, nextID: &untouchedID))
        XCTAssertNil(TrailerSceneEditor.split(5, atLocalTime: 1, source: videoSource(id: 9), in: &scenes, nextID: &untouchedID))
        XCTAssertEqual(scenes, snapshot)
        XCTAssertEqual(untouchedID, nextID)
        XCTAssertFalse(TrailerSceneEditor.canSplit(5, atLocalTime: 0.05, source: source, in: snapshot))
    }

    func testTrimClampsToTheOriginalAndMarksTheSceneProtected() {
        let source = videoSource(id: 1, duration: 20)
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 5, length: 4)]
        let before = scenes
        XCTAssertFalse(TrailerSceneEditor.trim(1, start: 18, length: 5, source: source, in: &scenes), "원본을 벗어난 범위는 거절합니다.")
        XCTAssertEqual(scenes, before)
        // 끝 손잡이를 원본 끝 너머로 끌어도 원본 끝에서 멈춘다.
        let window = TrailerSceneEditor.trimCandidate(scenes[0], edge: .end, by: 100, source: source)
        XCTAssertEqual((window?.start ?? -1) + (window?.length ?? 0), 20, accuracy: 1e-9)
        XCTAssertTrue(TrailerSceneEditor.trim(1, start: window?.start ?? 0, length: window?.length ?? 1, source: source, in: &scenes))
        XCTAssertEqual(scenes[0].manual, [.timing])
        XCTAssertFalse(scenes[0].automationProtected)
        XCTAssertEqual(scenes[0].start, 5, accuracy: 1e-9)
        // 사진은 표시 시간만 바뀐다.
        var photos = [photoScene(id: 2, sourceID: 2, length: 3, locked: false)]
        XCTAssertTrue(TrailerSceneEditor.trim(2, start: 0, length: 5, source: photoSource(id: 2), in: &photos))
        XCTAssertEqual(photos[0].length, 5, accuracy: 1e-9)
        XCTAssertEqual(photos[0].manual, [.timing])
    }

    func testUserReorderProtectsMovedScenesAndSkipsExcludedNeighbors() {
        let a = photoScene(id: 1, sourceID: 1, length: 2, locked: false)
        var hidden = photoScene(id: 2, sourceID: 1, length: 2, locked: false)
        hidden.excluded = true
        let b = photoScene(id: 3, sourceID: 2, length: 2, locked: false)
        var scenes = [a, hidden, b]
        XCTAssertTrue(TrailerSceneEditor.moveIncluded(3, step: -1, in: &scenes))
        XCTAssertEqual(scenes.map(\.id), [3, 1, 2], "제외된 장면은 건너뛰고 포함된 이웃 앞으로 갑니다.")
        XCTAssertEqual(scenes[0].manual, [.order], "옮긴 장면은 순서 의도만 표시합니다.")
        XCTAssertFalse(scenes[0].timingProtected, "옮겨도 시간은 계속 자동입니다.")
        XCTAssertTrue(scenes[1].manual.isEmpty)
        // 소스 순서 재배열도 자리가 바뀐 장면에 순서 의도만 표시한다.
        let moved = TrailerSceneEditor.reorderScenesBySourceOrder(scenes: [a, b], sourceIDs: [2, 1])
        XCTAssertEqual(moved.map(\.id), [3, 1])
        XCTAssertTrue(moved.allSatisfy { $0.manual == [.order] })
        let same = TrailerSceneEditor.reorderScenesBySourceOrder(scenes: [a, b], sourceIDs: [1, 2])
        XCTAssertEqual(same, [a, b])
    }

    // MARK: - 필드 단위 보호와 예산 (합성 데이터만 사용)

    func testCaptionAndAudioEditedSceneStillShrinksAndKeepsTheActionInside() {
        let sources = [videoSource(id: 1, duration: 30)]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 2, length: 10, actionStart: 6, actionEnd: 8)]
        TrailerSceneEditor.update(1, in: &scenes) {
            $0.caption = TrailerCaption(text: "자막")
            $0.volume = 0.4
            $0.muted = true
        }
        let edited = scenes[0]
        XCTAssertEqual(edited.manual, [.caption, .audio])
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 4)
        XCTAssertNotNil(fit)
        XCTAssertEqual(scenes[0].length, 4, accuracy: 0.01, "자막·소리만 고친 장면의 시간은 목표에 맞춰 줄어듭니다.")
        XCTAssertEqual(fit?.total ?? 0, 4, accuracy: 0.01)
        XCTAssertEqual(scenes[0].caption, edited.caption)
        XCTAssertEqual(scenes[0].volume, edited.volume)
        XCTAssertEqual(scenes[0].muted, edited.muted)
        XCTAssertEqual(scenes[0].manual, edited.manual, "자동 맞춤은 직접 편집 표시를 바꾸지 않습니다.")
        XCTAssertFalse(scenes[0].excluded)
        XCTAssertGreaterThanOrEqual(6, scenes[0].start - 1e-9, "동작 구간이 줄어든 창 안에 남습니다.")
        XCTAssertLessThanOrEqual(8, scenes[0].start + scenes[0].length + 1e-9)
    }

    func testBudgetDropsOnlyPureAutomaticScenesAndNeverTouchesManualWork() {
        let sources = (1...5).map { videoSource(id: $0, duration: 30) }
        func auto(_ id: Int, _ sourceID: Int) -> TrailerEditScene {
            TrailerEditScene(id: id, sourceID: sourceID, start: 2, length: 6, actionStart: 3, actionEnd: 5)
        }
        var scenes = [auto(1, 1), auto(2, 2), auto(3, 3), auto(4, 4), auto(5, 5),
                      TrailerEditScene(id: 6, sourceID: 1, start: 10, length: 6)]
        TrailerSceneEditor.update(4, in: &scenes) { $0.caption = TrailerCaption(text: "자막") }
        TrailerSceneEditor.update(5, in: &scenes) { $0.excluded = true }
        XCTAssertTrue(TrailerSceneEditor.trim(6, start: 10, length: 3.5, source: sources[0], in: &scenes))
        let original = scenes
        // 고정 3.5 + 못 빼는 자막 장면 최소 2 + 남는 2초: 순수 자동 장면(최소 2초) 하나만 들어간다.
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 7.5)
        XCTAssertEqual(fit?.total ?? 0, 7.5, accuracy: 0.01, "요청한 목표를 그대로 지킵니다.")
        XCTAssertEqual(scenes.map(\.id), original.map(\.id), "순서는 그대로입니다.")
        XCTAssertEqual(scenes[5], original[5], "시간을 직접 정한 장면은 바뀌지 않습니다.")
        XCTAssertEqual(scenes[4], original[4], "사용자가 제외한 장면은 그대로 제외입니다.")
        XCTAssertFalse(scenes[4].budgetExcluded)
        XCTAssertFalse(scenes[3].excluded, "자막이 있는 장면은 예산으로 빠지지 않습니다.")
        XCTAssertEqual(scenes[3].caption, original[3].caption)
        XCTAssertEqual(scenes[3].manual, original[3].manual)
        XCTAssertFalse(scenes[0].excluded, "가장 먼저 원하는 순수 자동 장면은 남습니다.")
        XCTAssertTrue(scenes[1].excluded && scenes[1].budgetExcluded)
        XCTAssertTrue(scenes[2].excluded && scenes[2].budgetExcluded)
        for index in [0, 3] {
            XCTAssertGreaterThanOrEqual(3, scenes[index].start - 1e-9)
            XCTAssertLessThanOrEqual(5, scenes[index].start + scenes[index].length + 1e-9, "동작 구간이 남은 창 안에 있습니다.")
        }
        // 예산이 커지면 예산으로 뺀 장면만 돌아오고 사용자 제외는 돌아오지 않는다.
        _ = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 60)
        XCTAssertFalse(scenes[1].excluded || scenes[2].excluded)
        XCTAssertTrue(scenes[4].excluded)
        XCTAssertEqual(scenes[5], original[5])
    }

    func testTinyTargetKeepsOneShortestWindowInsteadOfFailing() {
        let sources = [videoSource(id: 1, duration: 30)]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 2, length: 8, actionStart: 3, actionEnd: 8)]
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 0.5)
        XCTAssertNotNil(fit, "동작 구간이 목표보다 길어도 nil로 포기하지 않습니다.")
        XCTAssertFalse(scenes[0].excluded)
        XCTAssertEqual(scenes[0].length, 0.5, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(scenes[0].start, 3 - 1e-9, "기존 동작 구간 안의 시각만 씁니다.")
        XCTAssertLessThanOrEqual(scenes[0].start + scenes[0].length, 8 + 1e-9)
    }

    // MARK: - 피크 중심 좁히기 · 최종 권한 · 완결 흐름 (합성 피크 근거 사용)

    /// 자막·소리만 고친 동작 구간 [3, 8]은 시간이 자동이라 목표 2초를 지키며 실제 피크(5.5초)를 담도록 좁아진다.
    func testCaptionAudioActionNarrowsAroundTheRealPeakToReachTheTarget() {
        let source = spikeSource(id: 1, peak: 5.5)
        XCTAssertEqual(source.plan.rankedActionPeaks().first?.time ?? -1, 5.5, accuracy: 1e-9, "합성 근거가 실제 피크 경로를 탑니다.")
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 2, length: 10, actionStart: 3, actionEnd: 8)]
        TrailerSceneEditor.update(1, in: &scenes) {
            $0.caption = TrailerCaption(text: "자막")
            $0.volume = 0.4
            $0.muted = true
        }
        let edited = scenes[0]
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: [source], bodyTarget: 2)
        XCTAssertEqual(fit?.total ?? 0, 2, accuracy: 0.01)
        let narrowed = scenes[0]
        XCTAssertEqual(narrowed.length, 2, accuracy: 0.01, "동작 구간 전체(5초)로 목표를 늘리지 않고 요청한 2초를 지킵니다.")
        XCTAssertLessThanOrEqual(narrowed.start, 5.5, "좁힌 창이 실제 피크를 담습니다.")
        XCTAssertGreaterThanOrEqual(narrowed.start + narrowed.length, 5.5)
        XCTAssertGreaterThanOrEqual(narrowed.start, 3 - 1e-9, "기존 동작 구간 안의 시각만 씁니다.")
        XCTAssertLessThanOrEqual(narrowed.start + narrowed.length, 8 + 1e-9)
        XCTAssertEqual(narrowed.actionStart ?? -1, narrowed.start, accuracy: 1e-9, "좁힌 창이 새 동작 구간입니다.")
        XCTAssertEqual(narrowed.actionEnd ?? -1, narrowed.start + narrowed.length, accuracy: 1e-9)
        XCTAssertEqual(narrowed.manual, edited.manual)
        XCTAssertEqual(narrowed.caption, edited.caption)
        XCTAssertEqual(narrowed.volume, edited.volume)
        XCTAssertEqual(narrowed.muted, edited.muted)
        XCTAssertFalse(narrowed.excluded || narrowed.budgetExcluded, "직접 편집한 장면은 사라지지 않습니다.")
        let plan = TrailerPreparedPlan.manual(scenes, sources: [source])
        XCTAssertEqual(plan.first?.length ?? 0, narrowed.length, accuracy: 1e-9, "미리보기·내보내기 계획이 같은 길이입니다.")
        XCTAssertEqual(plan.first?.start ?? -1, narrowed.start, accuracy: 1e-9)
    }

    /// 더 중요한 긴 동작은 덜 중요한 짧은 클립이 통째로 들어간다는 이유만으로 밀려나지 않고, 먼저 피크 중심으로 좁혀 담긴다.
    func testHighImportanceLongActionIsNarrowedBeforeALowImportanceShortClipIsAccepted() {
        let long = spikeSource(id: 1, peak: 5.5)     // 동작 구간 [3, 11] 안에 피크 → 중요도 1
        let short = spikeSource(id: 2, peak: 20.5)   // 동작 구간 [3, 4] 밖에 피크 → 중요도 .5
        let sources = [long, short]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 3, length: 8, actionStart: 3, actionEnd: 11),
                      TrailerEditScene(id: 2, sourceID: 2, start: 3, length: 1, actionStart: 3, actionEnd: 4)]
        let peaks: (VideoTrailerSource) -> [VideoTrailerPlan.ActionPeak] = { $0.plan.rankedActionPeaks() }
        XCTAssertEqual(TrailerSceneEditor.sceneImportance(scenes[0], source: long, peaks: peaks), 1, accuracy: 1e-9)
        XCTAssertEqual(TrailerSceneEditor.sceneImportance(scenes[1], source: short, peaks: peaks), 0.5, accuracy: 1e-9)
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 5)
        XCTAssertEqual(fit?.total ?? 0, 5, accuracy: 0.01, "요청한 목표를 그대로 지킵니다.")
        XCTAssertFalse(scenes[0].excluded, "중요한 긴 동작이 남습니다.")
        XCTAssertTrue(scenes[1].excluded && scenes[1].budgetExcluded, "덜 중요한 짧은 클립이 대신 들어가지 않습니다.")
        XCTAssertEqual(scenes[0].length, 5, accuracy: 0.01)
        XCTAssertLessThanOrEqual(scenes[0].start, 5.5)
        XCTAssertGreaterThanOrEqual(scenes[0].start + scenes[0].length, 5.5, "좁힌 창이 피크를 담습니다.")
        XCTAssertGreaterThanOrEqual(scenes[0].start, 3 - 1e-9)
        XCTAssertLessThanOrEqual(scenes[0].start + scenes[0].length, 11 + 1e-9)
    }

    /// 자막 달린 소프트 2초 장면 + 뒤따르는 장면이 없는 순수 자동 8초 고중요 동작, 목표 5초(남는 자리 3초):
    /// 고중요 동작은 빠지지 않고 피크 중심으로 좁아져 둘 다 산다.
    func testMandatoryPlusSingleHighActionBothSurviveWithoutAnyLaterClip() {
        let manualSource = videoSource(id: 1)
        let high = spikeSource(id: 2, peak: 5.5)
        let sources = [manualSource, high]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 2, length: 2, actionStart: 2, actionEnd: 4),
                      TrailerEditScene(id: 2, sourceID: 2, start: 3, length: 8, actionStart: 3, actionEnd: 11)]
        TrailerSceneEditor.update(1, in: &scenes) { $0.caption = TrailerCaption(text: "자막") }
        let soft = TrailerSceneEditor.sceneDurationBounds(scene: scenes[0], source: manualSource).minimum
        XCTAssertEqual(soft, 2, accuracy: 1e-9, "자막 장면의 소프트 최소는 2초입니다.")
        XCTAssertTrue(scenes[1].isPureAutomatic)
        let original = scenes
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 5)
        XCTAssertEqual(fit?.total ?? 0, 5, accuracy: 0.01, "요청한 목표를 그대로 지킵니다.")
        XCTAssertEqual(fit?.excluded, 0, "뒤에 들어갈 장면이 없어도 고중요 동작을 빼지 않습니다.")
        XCTAssertFalse(scenes[0].excluded || scenes[0].budgetExcluded, "직접 편집한 장면은 사라지지 않습니다.")
        XCTAssertFalse(scenes[1].excluded || scenes[1].budgetExcluded, "고중요 동작이 남습니다.")
        XCTAssertGreaterThanOrEqual(scenes[0].length, 2 - 1e-9, "자막 장면이 목표를 채우려고 늘어나는 대신 동작 구간을 지킵니다.")
        XCTAssertLessThan(scenes[1].length, 8, "고중요 동작은 남은 자리에 맞춰 좁아집니다.")
        XCTAssertLessThanOrEqual(scenes[1].length, 3 + 1e-9)
        XCTAssertLessThanOrEqual(scenes[1].start, 5.5, "좁힌 창이 실제 피크를 담습니다.")
        XCTAssertGreaterThanOrEqual(scenes[1].start + scenes[1].length, 5.5)
        XCTAssertGreaterThanOrEqual(scenes[1].start, 3 - 1e-9)
        XCTAssertLessThanOrEqual(scenes[1].start + scenes[1].length, 11 + 1e-9)
        XCTAssertEqual(scenes[0].caption, original[0].caption)
        XCTAssertEqual(scenes[0].manual, original[0].manual)
        XCTAssertEqual(scenes.map(\.id), original.map(\.id))
    }

    /// 남는 자리가 UI 최소(0.2초)보다 작아도 물리적 최소(1/30초) 이상이면 고중요 동작은 그 자리에 좁혀 담긴다.
    func testRemainderBelowUIMinimumStillKeepsTheHighActionAtTheFrameFloor() {
        let manualSource = videoSource(id: 1)
        let high = spikeSource(id: 2, peak: 5.5)
        let sources = [manualSource, high]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 2, length: 2, actionStart: 2, actionEnd: 4),
                      TrailerEditScene(id: 2, sourceID: 2, start: 3, length: 8, actionStart: 3, actionEnd: 11)]
        TrailerSceneEditor.update(1, in: &scenes) { $0.caption = TrailerCaption(text: "자막") }
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 2.1)
        XCTAssertEqual(fit?.total ?? 0, 2.1, accuracy: 0.01, "남는 0.1초도 목표 안에서 씁니다.")
        XCTAssertFalse(scenes[1].excluded || scenes[1].budgetExcluded, "0.2초 UI 최소가 물리적 최소(1/30초) 이상의 자리를 막지 않습니다.")
        XCTAssertGreaterThanOrEqual(scenes[1].length, TrailerSceneEditor.frameMinimum - 1e-9)
        XCTAssertLessThan(scenes[1].length, 0.2, "UI 최소로 늘어나지 않습니다.")
        XCTAssertLessThanOrEqual(scenes[1].start, 5.5, "좁힌 창이 실제 피크를 담습니다.")
        XCTAssertGreaterThanOrEqual(scenes[1].start + scenes[1].length, 5.5)
        XCTAssertFalse(scenes[0].excluded || scenes[0].budgetExcluded)
        XCTAssertEqual(scenes[0].caption, TrailerCaption(text: "자막"))
        let plan = TrailerPreparedPlan.manual(scenes, sources: sources)
        XCTAssertEqual(plan.count, 2, "미리보기·내보내기 계획에도 둘 다 남습니다.")
        XCTAssertEqual(plan.last?.length ?? 0, scenes[1].length, accuracy: 1e-9)
    }

    /// 이미 담긴 가장 중요한 자동 장면 뒤에 같은 고중요의 긴 동작이 오고 그 뒤에는 덜 중요한 장면이 없을 때, 남는 0.1초(UI 최소 0.2초 미만,
    /// 1/30초 이상)에도 긴 동작이 빠지지 않고 피크 중심으로 좁혀 둘 다 실제 계획 창 안에 자기 피크를 담는다. 고정 장면은 그대로다.
    func testSecondHighActionIsNarrowedToTheRemainderWithNoLaterLowClip() {
        let first = spikeSource(id: 1, peak: 5.5)
        let second = spikeSource(id: 2, peak: 5.5)
        let fixedSource = videoSource(id: 3, duration: 30)
        let sources = [first, second, fixedSource]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 3, length: 4.4, actionStart: 3, actionEnd: 7.4),
                      TrailerEditScene(id: 2, sourceID: 2, start: 3, length: 8, actionStart: 3, actionEnd: 11),
                      TrailerEditScene(id: 3, sourceID: 3, start: 10, length: 6)]
        XCTAssertTrue(TrailerSceneEditor.trim(3, start: 10, length: 1, source: fixedSource, in: &scenes))
        let peaks: (VideoTrailerSource) -> [VideoTrailerPlan.ActionPeak] = { $0.plan.rankedActionPeaks() }
        XCTAssertEqual(TrailerSceneEditor.sceneImportance(scenes[0], source: first, peaks: peaks), 1, accuracy: 1e-9)
        XCTAssertEqual(TrailerSceneEditor.sceneImportance(scenes[1], source: second, peaks: peaks), 1, accuracy: 1e-9)
        XCTAssertTrue(scenes[0].isPureAutomatic && scenes[1].isPureAutomatic)
        let original = scenes
        // 고정 1초를 뺀 자동 몫 4.5초에서 첫 장면이 4.4초를 쓰면 0.1초가 남는다.
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 5.5)
        XCTAssertEqual(fit?.total ?? 0, 5.5, accuracy: 0.01, "요청한 목표를 그대로 지킵니다.")
        XCTAssertEqual(fit?.excluded, 0, "뒤에 덜 중요한 장면이 없어도 긴 고중요 동작을 빼지 않습니다.")
        XCTAssertFalse(scenes[0].excluded || scenes[1].excluded)
        XCTAssertEqual(scenes[0].length, 4.4, accuracy: 0.01, "먼저 담긴 장면은 통째로입니다.")
        XCTAssertEqual(scenes[1].length, 0.1, accuracy: 0.01, "긴 동작은 남은 0.1초로 좁혀지고 UI 최소로 늘어나지 않습니다.")
        XCTAssertGreaterThanOrEqual(scenes[1].length, TrailerSceneEditor.frameMinimum - 1e-9)
        XCTAssertEqual(scenes[2], original[2], "시간을 직접 정한 장면은 구간까지 그대로입니다.")
        let plan = TrailerPreparedPlan.manual(scenes, sources: sources)
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan.reduce(0.0) { $0 + $1.length }, 5.5, accuracy: 0.01, "계획 실제 길이도 요청한 합계입니다.")
        for index in 0...1 {
            XCTAssertLessThanOrEqual(plan[index].start, 5.5 + 1e-9, "계획 창이 자기 피크를 담습니다.")
            XCTAssertGreaterThanOrEqual(plan[index].start + plan[index].length, 5.5 - 1e-9)
            XCTAssertGreaterThanOrEqual(plan[index].start, 3 - 1e-9, "기존 동작 구간 안의 시각만 씁니다.")
            XCTAssertEqual(plan[index].length, scenes[index].length, accuracy: 1e-9)
        }
        XCTAssertLessThanOrEqual(plan[1].start + plan[1].length, 11 + 1e-9)
        XCTAssertEqual(scenes.map(\.id), original.map(\.id))
    }

    /// 직접 시간을 정한 장면은 구간까지 그대로, 순수 자동 장면은 못 빼는 직접 편집 장면을 좁히기 전에 먼저 빠진다.
    func testFixedTimingStaysExactAndPureAutomaticIsExcludedBeforeManualWorkIsNarrowed() {
        let sources = [spikeSource(id: 1, peak: 5.5), videoSource(id: 2), videoSource(id: 3)]
        var scenes = [TrailerEditScene(id: 1, sourceID: 2, start: 2, length: 6, actionStart: 3, actionEnd: 5),
                      TrailerEditScene(id: 2, sourceID: 1, start: 2, length: 10, actionStart: 3, actionEnd: 8),
                      TrailerEditScene(id: 3, sourceID: 3, start: 10, length: 6)]
        TrailerSceneEditor.update(2, in: &scenes) { $0.caption = TrailerCaption(text: "자막") }
        XCTAssertTrue(TrailerSceneEditor.trim(3, start: 10, length: 3.5, source: sources[2], in: &scenes))
        let original = scenes
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 6)
        XCTAssertEqual(fit?.total ?? 0, 6, accuracy: 0.01)
        XCTAssertEqual(scenes[2], original[2], "직접 정한 시간 구간은 그대로입니다.")
        XCTAssertTrue(scenes[0].excluded && scenes[0].budgetExcluded, "순수 자동 장면이 먼저 빠집니다.")
        XCTAssertFalse(scenes[1].excluded, "자막 장면은 빠지지 않습니다.")
        XCTAssertEqual(scenes[1].length, 2.5, accuracy: 0.01, "고정 3.5초를 뺀 나머지 2.5초로 좁아집니다.")
        XCTAssertEqual(scenes[1].caption, original[1].caption)
        XCTAssertEqual(scenes[1].manual, original[1].manual)
        XCTAssertLessThanOrEqual(scenes[1].start, 5.5)
        XCTAssertGreaterThanOrEqual(scenes[1].start + scenes[1].length, 5.5)
        XCTAssertEqual(scenes.map(\.id), original.map(\.id))
    }

    /// 프레임 한 장에 가까운 목표도 실제 계획·저장·다시 열기에서 0.2초로 늘지 않고 그대로 산다.
    func testTargetNearOneFrameSurvivesThePlanAndSaveReopen() throws {
        let source = spikeSource(id: 1, peak: 5.5)
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 2, length: 10, actionStart: 3, actionEnd: 8)]
        TrailerSceneEditor.update(1, in: &scenes) { $0.caption = TrailerCaption(text: "자막") }
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: [source], bodyTarget: 0.05)
        XCTAssertEqual(fit?.total ?? 0, 0.05, accuracy: 1e-6)
        XCTAssertEqual(scenes[0].length, 0.05, accuracy: 1e-9, "UI 최소 0.2초는 물리적 한계가 아닙니다.")
        XCTAssertLessThanOrEqual(scenes[0].start, 5.5)
        XCTAssertGreaterThanOrEqual(scenes[0].start + scenes[0].length, 5.5)
        let plan = TrailerPreparedPlan.manual(scenes, sources: [source])
        XCTAssertEqual(plan.first?.length ?? 0, 0.05, accuracy: 1e-9, "미리보기·내보내기 계획이 조용히 늘리지 않습니다.")
        let reopened = try JSONDecoder().decode([TrailerEditScene].self, from: JSONEncoder().encode(scenes))
        XCTAssertEqual(reopened, scenes)
        let reopenedPlan = TrailerPreparedPlan.manual(reopened, sources: [source])
        XCTAssertEqual(reopenedPlan.first?.length ?? 0, 0.05, accuracy: 1e-9, "저장하고 다시 열어도 같은 길이입니다.")
        XCTAssertEqual(reopenedPlan.first?.start ?? -1, plan.first?.start ?? -2, accuracy: 1e-9)
        // 직접 다듬기의 UI 최소 길이는 그대로다.
        XCTAssertEqual(TrailerSceneEditor.sceneDurationBounds(scene: TrailerEditScene(id: 9, sourceID: 1, start: 0, length: 1), source: source).minimum,
                       0.2, accuracy: 1e-9)
    }

    /// 자막·소리·순서를 고친 AB는 음악이 더 길어도 ABAB로 반복되거나 꼬리가 잘리지 않고, 표시 길이가 계획 길이와 같다.
    func testEditedListIsTheFinalPlanAndTheMusicFitNeverRepeatsIt() {
        let sources = [videoSource(id: 1), videoSource(id: 2)]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 2), TrailerEditScene(id: 2, sourceID: 2, start: 1, length: 2)]
        let music = TrailerMusicSelection(recordID: UUID(), name: "m", url: dummyURL, duration: 10, policy: .fitMusic)
        func plan() -> [VideoTrailerScene] {
            TrailerPreparedPlan.scenes(mode: .trailer, sources: sources, total: 10, clipLength: 4, music: music,
                                       manual: scenes, cardsDuration: 0)
        }
        // 전부 순수 자동이면 원래의 음악 길이 맞춤 반복 규칙이 그대로다.
        XCTAssertFalse(TrailerSceneEditor.keepsManualScenesAsIs(scenes))
        let repeated = plan()
        XCTAssertEqual(repeated.reduce(0) { $0 + $1.length }, 10, accuracy: 0.01)
        XCTAssertGreaterThan(repeated.count, 2)
        // 자막·소리를 고치면 목록이 곧 최종 계획이다.
        TrailerSceneEditor.update(1, in: &scenes) { $0.caption = TrailerCaption(text: "A") }
        TrailerSceneEditor.update(2, in: &scenes) { $0.volume = 0.3 }
        XCTAssertTrue(TrailerSceneEditor.keepsManualScenesAsIs(scenes))
        let exact = plan()
        XCTAssertEqual(exact.map(\.sourceID), [1, 2], "정확히 한 번씩, 같은 순서입니다.")
        XCTAssertEqual(exact.map(\.length), [2, 2])
        XCTAssertEqual(exact.map(\.start), [0, 1])
        XCTAssertEqual(exact.first?.caption?.text, "A")
        XCTAssertEqual(exact.last?.volume ?? -1, 0.3, accuracy: 1e-9)
        let cards = 1.0
        XCTAssertEqual(TrailerSceneEditor.effectiveFitDuration(fitted: music.fittedDuration, scenes: scenes, cardsDuration: cards),
                       exact.reduce(0) { $0 + $1.length } + cards, accuracy: 1e-9,
                       "표시하는 실제 길이는 계획·내보내기 장면 길이 합과 같습니다.")
        // 순서를 바꾼 목록도 정확히 그 순서 그대로다.
        XCTAssertTrue(TrailerSceneEditor.moveIncluded(2, step: -1, in: &scenes))
        let reordered = plan()
        XCTAssertEqual(reordered.map(\.sourceID), [2, 1])
        XCTAssertEqual(reordered.reduce(0) { $0 + $1.length }, 4, accuracy: 1e-9)
    }

    /// 추천이 바꿀 값이 없거나 선택한 클립의 시간이 모두 고정이어도 거절하지 않고, 고른 클립 안에서만 길이 맞춤을 마무리한다.
    func testFixedOrUnchangedSelectionStillReconcilesTheBudgetWithinCapturedIDs() {
        let photo = photoSource(id: 2)
        let sources = [videoSource(id: 1), photo]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 2, length: 6),
                      TrailerEditScene(id: 2, sourceID: 1, start: 12, length: 6),
                      TrailerEditScene(id: 3, sourceID: 2, start: 0, length: photo.weightedImageLength(clipLength: 4)),
                      photoScene(id: 4, sourceID: 2, length: 4, locked: false)]
        XCTAssertTrue(TrailerSceneEditor.trim(1, start: 2, length: 3.5, source: sources[0], in: &scenes))
        XCTAssertTrue(TrailerSceneEditor.trim(2, start: 12, length: 2, source: sources[0], in: &scenes))
        // 1) 선택한 클립이 모두 고정: 추천은 아무것도 바꾸지 않고, 맞춤도 값을 그대로 둔 채 실제 합계를 돌려준다.
        let before = scenes
        let fixedOnly: Set<Int> = [1, 2]
        XCTAssertEqual(TrailerSceneEditor.automationCounts(ids: fixedOnly, in: scenes).eligible, 0)
        XCTAssertEqual(TrailerSceneEditor.refreshAutomaticScenes(ids: fixedOnly, sources: sources, clipLength: 4, in: &scenes), 0)
        var fixedFit: (total: Double, included: Int, excluded: Int)?
        TrailerSceneEditor.freezing(except: fixedOnly, in: &scenes) { list in
            fixedFit = TrailerSceneEditor.fitScenesToBudget(scenes: &list, sources: sources, bodyTarget: 20)
        }
        XCTAssertNotNil(fixedFit, "고정된 클립만 골라도 맞춤은 끝까지 갑니다.")
        XCTAssertEqual(scenes, before, "고정한 클립과 고르지 않은 클립은 값·표시가 모두 그대로입니다.")
        // 2) 추천이 바꿀 값이 없어도(이미 같음) 고른 자동 클립은 남은 예산을 받아 맞춰진다. 고르지 않은 클립은 그대로다.
        let ids: Set<Int> = [1, 3]
        XCTAssertEqual(TrailerSceneEditor.automationCounts(ids: ids, in: scenes).eligible, 1)
        XCTAssertEqual(TrailerSceneEditor.refreshAutomaticScenes(ids: ids, sources: sources, clipLength: 4, in: &scenes), 0)
        var fit: (total: Double, included: Int, excluded: Int)?
        TrailerSceneEditor.freezing(except: ids, in: &scenes) { list in
            fit = TrailerSceneEditor.fitScenesToBudget(scenes: &list, sources: sources, bodyTarget: 12)
        }
        XCTAssertEqual(fit?.total ?? 0, 12, accuracy: 0.01, "고정 3.5 + 2 + 4를 뺀 2.5초를 고른 자동 클립이 받습니다.")
        XCTAssertEqual(scenes[2].length, 2.5, accuracy: 0.01)
        XCTAssertEqual(scenes[0], before[0], "고정한 클립은 그대로입니다.")
        XCTAssertEqual(scenes[1], before[1], "고르지 않은 클립은 그대로입니다.")
        XCTAssertEqual(scenes[3], before[3])
    }

    /// 손잡이를 끈 거리는 손잡이 폭이 아니라 원본 범위로만 제한되고, 입력 뷰의 기본 콜백은 필름스트립의 기존 호출을 그대로 둔다.
    @MainActor
    func testHandleDragIsBoundedBySourceNotHandleWidthAndNativeInputDefaultsAreInert() {
        let source = videoSource(id: 1, duration: 20)
        let scene = TrailerEditScene(id: 1, sourceID: 1, start: 5, length: 4)
        // 16pt 손잡이를 훨씬 넘어 끈 3초(예: 300pt)도 그대로 반영된다.
        XCTAssertEqual(TrailerSceneEditor.trimCandidate(scene, edge: .end, by: 3, source: source)?.length ?? 0, 7, accuracy: 1e-9)
        XCTAssertEqual(TrailerSceneEditor.trimCandidate(scene, edge: .start, by: -2, source: source)?.start ?? 0, 3, accuracy: 1e-9)
        var pressed: Double?
        let input = TrailerTimelineNativeInput(onPress: { pressed = $0 })
        input.onHover(0.5)
        input.onHoverEnd()
        input.onDrag(0.2)
        input.onRelease(0.3, false)
        XCTAssertNil(pressed, "생략한 콜백은 아무 일도 하지 않습니다.")
        input.onPress(0.4)
        XCTAssertEqual(pressed, 0.4)
        XCTAssertNil(input.onTranslation)
    }

    func testPreviewPlanDisplayedTotalAndFixedScenesAgree() {
        let sources = [videoSource(id: 1, duration: 30), photoSource(id: 2)]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 2, length: 10),
                      photoScene(id: 2, sourceID: 2, length: 8, locked: false)]
        TrailerSceneEditor.update(1, in: &scenes) { $0.caption = TrailerCaption(text: "자막") }
        let music = TrailerMusicSelection(recordID: UUID(), name: "m", url: dummyURL, duration: 6, policy: .fitMusic)
        let fit = TrailerSceneEditor.fitScenesToMusic(scenes: &scenes, sources: sources, musicDuration: 6, startCount: 1,
                                                      cardsDuration: 0, maximumRepeats: 600)
        XCTAssertTrue(fit.fits)
        XCTAssertTrue(TrailerSceneEditor.keepsManualScenesAsIs(scenes), "자막을 고친 목록은 시간이 자동이어도 편집 목록이 곧 최종 계획입니다.")
        let plan = TrailerPreparedPlan.scenes(mode: .trailer, sources: sources, total: 6, clipLength: 4, music: music,
                                              manual: scenes, cardsDuration: 0)
        XCTAssertEqual(plan.count, 2, "두 번째 맞춤이 장면을 반복하거나 자르지 않습니다.")
        XCTAssertEqual(plan.reduce(0) { $0 + $1.length }, 6, accuracy: 0.01, "미리보기 계획이 음악 길이와 같습니다.")
        XCTAssertEqual(plan.reduce(0) { $0 + $1.length }, fit.total, accuracy: 0.01)
        XCTAssertEqual(plan.first?.caption?.text, "자막")
        XCTAssertEqual(TrailerSceneEditor.effectiveFitDuration(fitted: music.fittedDuration, scenes: scenes, cardsDuration: 0), 6, accuracy: 0.01)
        // 시간을 직접 정한 장면이 음악보다 길면 목록이 곧 결과이고 표시 길이도 실제 길이다.
        var fixed = scenes
        XCTAssertTrue(TrailerSceneEditor.trim(1, start: 2, length: 9, source: sources[0], in: &fixed))
        XCTAssertTrue(TrailerSceneEditor.keepsManualScenesAsIs(fixed))
        let fixedPlan = TrailerPreparedPlan.scenes(mode: .trailer, sources: sources, total: 6, clipLength: 4, music: music,
                                                   manual: fixed, cardsDuration: 0)
        let actual = fixed.filter { !$0.excluded }.reduce(0.0) { $0 + $1.length }
        XCTAssertEqual(fixedPlan.reduce(0) { $0 + $1.length }, actual, accuracy: 0.01, "고정 장면은 두 번째 맞춤에서 잘리지 않습니다.")
        XCTAssertEqual(TrailerSceneEditor.effectiveFitDuration(fitted: music.fittedDuration, scenes: fixed, cardsDuration: 0), actual, accuracy: 0.01)
    }

    func testDuplicateAndLockToggleKeepFieldMetadata() {
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 2, length: 6)]
        TrailerSceneEditor.update(1, in: &scenes) { $0.caption = TrailerCaption(text: "자막") }
        var nextID = 2
        let copyID = TrailerSceneEditor.duplicate(1, in: &scenes, nextID: &nextID)
        XCTAssertNotNil(copyID)
        XCTAssertTrue(scenes[1].manual.isSuperset(of: [.caption, .order, .exclusion]), "복제본은 원래 표시를 잇고 포함·순서 의도를 갖습니다.")
        XCTAssertFalse(scenes[1].timingProtected, "복제만으로 시간을 고정하지 않습니다.")
        XCTAssertEqual(scenes[0].manual, [.caption])
        // 잠금은 전체 보호를 켜고, 해제는 시간·순서·제외 표시를 지우되 자막 표시는 남긴다.
        XCTAssertEqual(TrailerSceneEditor.setAutomationProtected(true, ids: [1], in: &scenes), 1)
        XCTAssertTrue(scenes[0].timingProtected)
        XCTAssertEqual(TrailerSceneEditor.setAutomationProtected(false, ids: [1], in: &scenes), 1)
        XCTAssertFalse(scenes[0].timingProtected)
        XCTAssertEqual(scenes[0].manual, [.caption])
        XCTAssertEqual(scenes[0].caption?.text, "자막")
    }

    func testTimelineGeometryMapsPlayheadIntoTheSelectedClipOnly() {
        let segments = [
            TrailerTimelineSegment(id: "intro", kind: .intro, sceneID: nil, sourceID: nil, start: 0, length: 2),
            TrailerTimelineSegment(id: "scene-1", kind: .clip, sceneID: 1, sourceID: 1, start: 0, length: 4),
            TrailerTimelineSegment(id: "scene-2", kind: .clip, sceneID: 2, sourceID: 1, start: 0, length: 4)
        ]
        XCTAssertEqual(TrailerTimelineGeometry.total(segments), 10, accuracy: 1e-9)
        let playhead = TrailerTimelineGeometry.playheadSeconds(currentSeconds: 5, durationSeconds: 10, hasPlayer: true, segments: segments)
        XCTAssertEqual(playhead ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(TrailerTimelineGeometry.localTime(ofScene: 1, atSeconds: playhead, segments: segments) ?? -1, 3, accuracy: 1e-9,
                       "시작 화면 길이만큼 밀린 출력 시각이 장면 안 시각으로 바뀝니다.")
        XCTAssertNil(TrailerTimelineGeometry.localTime(ofScene: 2, atSeconds: playhead, segments: segments), "선택한 클립 밖은 나눌 수 없습니다.")
        XCTAssertNil(TrailerTimelineGeometry.playheadSeconds(currentSeconds: 5, durationSeconds: 10, hasPlayer: false, segments: segments))
    }

    // MARK: - 고급 편집 (배속·디졸브·키프레임·자막 큐·해설)

    @MainActor
    func testRateScalesOutputDurationAndDissolveSubtractsOverlapOnce() throws {
        let rate2 = try TrailerClipTimeMappingFactory.buildTimelineMappings(clips: [
            TrailerClipInput(sceneID: 0, sourceID: 1, sourceStart: 0, sourceLength: 10, rate: 2)])
        XCTAssertEqual(rate2[0].outputDuration, 5, accuracy: 1e-9)
        let cue = TrailerTimedCaptionCue(sourceID: 1, sourceStart: 5, sourceEnd: 6, text: "a")
        XCTAssertEqual(rate2[0].mapAndClipCue(cue)?.outputStart ?? -1, 2.5, accuracy: 1e-9)
        let dissolved = try TrailerClipTimeMappingFactory.buildTimelineMappings(clips: [
            TrailerClipInput(sceneID: 0, sourceID: 1, sourceStart: 0, sourceLength: 5, requestedOutgoingOverlap: 1),
            TrailerClipInput(sceneID: 1, sourceID: 2, sourceStart: 0, sourceLength: 5)])
        XCTAssertEqual(dissolved[1].outputStart, 4, accuracy: 1e-9)
        XCTAssertEqual(dissolved[1].outputStart + dissolved[1].outputDuration, 9, accuracy: 1e-9)
        var segments = [
            TrailerTimelineSegment(id: "a", kind: .clip, sceneID: 1, sourceID: 1, start: 0, length: 5,
                                   adjustments: TrailerClipAdjustments(transition: TrailerTransition(dissolveDuration: 1))),
            TrailerTimelineSegment(id: "b", kind: .clip, sceneID: 2, sourceID: 2, start: 0, length: 5)]
        segments = TrailerAdvancedComposer.annotatingOverlaps(segments)
        XCTAssertEqual(TrailerTimelineGeometry.total(segments), 9, accuracy: 1e-9, "타임라인 길이도 겹침을 한 번만 뺍니다.")
    }

    func testAdjustmentsRoundTripAndKeepKeyframesOutsideTrim() throws {
        var scene = TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 4)
        let keyframe = TrailerTransformKeyframe(sourceTime: 2, offsetX: 0.2)
        scene.adjustments = TrailerClipAdjustments(rate: 2, keyframes: [keyframe])
        var scenes = [scene]
        // 키프레임(2초)은 창 전체를 고정하지 않고(시간 자동) 그 시각만 자동 맞춤이 지켜야 하는 앵커다.
        XCTAssertFalse(scenes[0].timingProtected)
        XCTAssertEqual(scenes[0].protectedSpan?.start ?? -1, 2, accuracy: 1e-9)
        // 직접 트림으로 3~4초만 남겨도 저장된 점은 그대로이고, 다시 늘리면 창 안으로 돌아온다.
        TrailerSceneEditor.update(1, in: &scenes) { $0.start = 3; $0.length = 1 }
        XCTAssertEqual(scenes[0].adjustments?.keyframes, [keyframe])
        XCTAssertTrue(scenes[0].manual.contains(.timing))
        let data = try JSONEncoder().encode(scenes[0])
        let decoded = try JSONDecoder().decode(TrailerEditScene.self, from: data)
        XCTAssertEqual(decoded.adjustments, scenes[0].adjustments)
        XCTAssertEqual(decoded.adjustments?.rate, 2)
        // 이전 버전 저장본은 중립으로 읽는다.
        let legacy = try JSONDecoder().decode(TrailerEditScene.self, from: JSONEncoder().encode(TrailerEditScene(id: 2, sourceID: 1, start: 0, length: 2)))
        XCTAssertNil(legacy.adjustments)
        XCTAssertNil(TrailerPreparedPlan.manual([legacy], sources: [videoSource(id: 1)]).first?.adjustments)
    }

    func testManualScenePlanCarriesAdjustmentsAndOutputLength() {
        var scene = TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 4)
        scene.adjustments = TrailerClipAdjustments(rate: 2, color: TrailerColorAdjustment(brightness: 0.2))
        let planned = TrailerPreparedPlan.manual([scene], sources: [videoSource(id: 1)])
        XCTAssertEqual(planned.first?.adjustments?.rate, 2)
        XCTAssertEqual(planned.first?.outputLength ?? -1, 2, accuracy: 1e-9)
        XCTAssertTrue(planned.first?.hasAdvancedEdits ?? false)
    }

    func testCueMergeKeepsManualCuesAndSuppressedRanges() {
        let manual = TrailerTimedCaptionCue(sourceID: 1, sourceStart: 1, sourceEnd: 2, text: "내 자막", origin: .manual, manuallyEdited: true)
        let overlapping = TrailerTimedCaptionCue(sourceID: 1, sourceStart: 1.2, sourceEnd: 1.8, text: "생성", origin: .generated)
        let deleted = TrailerTimedCaptionCue(sourceID: 1, sourceStart: 5, sourceEnd: 6, text: "지운 것", origin: .generated)
        let fresh = TrailerTimedCaptionCue(sourceID: 1, sourceStart: 8, sourceEnd: 9, text: "새 것", origin: .generated)
        let merged = TrailerTimedCaptionCue.merge(
            existingCues: [manual], newGeneratedCues: [overlapping, deleted, fresh],
            suppressions: [TrailerCueSuppression(sourceID: 1, sourceStart: 5, sourceEnd: 6)])
        XCTAssertEqual(merged.map(\.text), ["내 자막", "새 것"])
        XCTAssertEqual(merged.first?.stableID, manual.stableID)
    }

    func testVoiceoverFloorAndPlacementNeverTruncateManualTake() {
        let take = TrailerVoiceoverTake(relativeFile: "media/voice-x.m4a", outputStart: 2, sourceIn: 0.5, sourceOut: 6.5)
        XCTAssertEqual(take.requiredOutputEnd ?? -1, 8, accuracy: 1e-9)
        let input = TrailerDraftPreviewInput(
            segments: [TrailerTimelineSegment(id: "a", kind: .clip, sceneID: 1, sourceID: 1, start: 0, length: 4)],
            sources: [], captions: [:], introCard: TrailerTitleCard(), outroCard: TrailerTitleCard(),
            introBackground: nil, outroBackground: nil, bodyTypography: nil, selectedSceneID: nil, music: nil,
            voices: [TrailerComposerVoice(take: take, url: URL(fileURLWithPath: "/dummy"))])
        XCTAssertEqual(input.totalDuration, 8, accuracy: 1e-9, "해설이 요구하는 끝이 영상보다 길면 그 길이가 전체 길이입니다.")
        XCTAssertTrue(input.usesAdvanced)
    }

    /// 배속·디졸브·큐·키프레임은 창 전체를 고정하지 않는다. 직접 놓은 큐 구간은 출력 시간으로 줄인 예산에서도 창 안에 남는다.
    func testRateAndCueDoNotLockTheWindowButTheCueAnchorSurvivesAnOutputBudget() {
        let source = spikeSource(id: 1, peak: 5.5)
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 2, length: 10, actionStart: 3, actionEnd: 8)]
        TrailerSceneEditor.update(1, in: &scenes) { scene in
            var value = scene.adjustments ?? TrailerClipAdjustments()
            value.rate = 2
            value.transition = TrailerTransition(dissolveDuration: 1)
            value.cues = [TrailerTimedCaptionCue(sourceID: 1, sourceStart: 4, sourceEnd: 5, text: "내 자막", origin: .manual, manuallyEdited: true)]
            scene.adjustments = value
        }
        XCTAssertFalse(scenes[0].manual.contains(.timing), "배속·디졸브·큐는 시간 창 잠금이 아닙니다.")
        XCTAssertTrue(scenes[0].manual.contains(.adjust))
        XCTAssertFalse(scenes[0].timingProtected)
        // 출력 목표 1초 = 원본 2초: 큐(4~5초)가 창에 남고 둘레 문맥은 줄어든다.
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: [source], bodyTarget: 1)
        XCTAssertEqual(fit?.total ?? 0, 1, accuracy: 1e-3)
        XCTAssertEqual(scenes[0].length, 2, accuracy: 1e-3, "원본 길이는 출력 길이 × 배속입니다.")
        XCTAssertLessThanOrEqual(scenes[0].start, 4 + 1e-6)
        XCTAssertGreaterThanOrEqual(scenes[0].start + scenes[0].length, 5 - 1e-6)
        XCTAssertEqual(scenes[0].adjustments?.rate, 2)
        XCTAssertEqual(scenes[0].adjustments?.cues.count, 1)
    }

    /// 두 5초 클립 사이 1초 디졸브는 출력에서 한 번만 빠지고 예산이 같은 출력 시간표로 맞는다.
    func testBudgetUsesOutputTimeWithRateAndOverlapCountedOnce() {
        let sources = [videoSource(id: 1, duration: 60), videoSource(id: 2, duration: 60)]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 5), TrailerEditScene(id: 2, sourceID: 2, start: 0, length: 5)]
        TrailerSceneEditor.update(1, in: &scenes) { $0.adjustments = TrailerClipAdjustments(transition: TrailerTransition(dissolveDuration: 1)) }
        XCTAssertEqual(TrailerSceneEditor.outputBodyDuration(scenes), 9, accuracy: 1e-9)
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 12)
        XCTAssertEqual(fit?.total ?? 0, 12, accuracy: 1e-2)
        XCTAssertEqual(TrailerSceneEditor.outputBodyDuration(scenes), 12, accuracy: 1e-2, "예산 합과 출력 시간표가 같습니다.")
        // 10 원본 초를 2배로 틀면 출력 5초, 물리적 하한은 출력 프레임 한 장이다.
        var fast = [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 10)]
        TrailerSceneEditor.update(1, in: &fast) { $0.adjustments = TrailerClipAdjustments(rate: 2) }
        XCTAssertEqual(TrailerSceneEditor.outputBodyDuration(fast), 5, accuracy: 1e-9)
        XCTAssertEqual(TrailerSceneEditor.fitScenesToBudget(scenes: &fast, sources: sources, bodyTarget: 8)?.total ?? 0, 8, accuracy: 1e-2)
        XCTAssertEqual(fast[0].length, 16, accuracy: 0.05, "출력 8초 = 원본 16초(배속 2).")
        // 타임라인에서 끈 거리는 출력 초이므로 배속 2에서는 원본이 두 배 움직인다.
        XCTAssertEqual(TrailerSceneEditor.trimCandidate(fast[0], edge: .end, by: -1, source: sources[0])?.length ?? 0, fast[0].length - 2, accuracy: 1e-9)
    }

    /// 0.25배속에서 출력 한 프레임(1/30초)은 원본 1/120초다: 원본 1/30초 바닥으로 4프레임을 부풀리지 않는다.
    func testSlowRateOneOutputFrameIsNotInflatedByTheSourceFloor() {
        let sources = [videoSource(id: 1, duration: 60)]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 8)]
        TrailerSceneEditor.update(1, in: &scenes) { $0.adjustments = TrailerClipAdjustments(rate: 0.25) }
        let frame = TrailerSceneEditor.frameMinimum
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: frame)
        XCTAssertEqual(fit?.total ?? 0, frame, accuracy: 1e-6, "출력은 정확히 한 프레임입니다.")
        XCTAssertEqual(scenes[0].length, frame * 0.25, accuracy: 1e-6, "원본 길이는 1/120초입니다(1/30초 아님).")
        XCTAssertEqual(scenes[0].adjustments?.rate, 0.25)
    }

    /// 사진의 직접 놓은 키프레임(논리 사진 시간)은 `isImage`라고 사라지지 않고, 예산이 줄여도 보이는 구간에 남는다.
    func testPhotoKeyframeAnchorSurvivesTheOutputBudget() {
        let sources = [photoSource(id: 1)]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 6)]
        TrailerSceneEditor.update(1, in: &scenes) {
            $0.adjustments = TrailerClipAdjustments(keyframes: [TrailerTransformKeyframe(sourceTime: 4, offsetX: 0.2)])
        }
        XCTAssertFalse(scenes[0].timingProtected, "키프레임은 시간 창 잠금이 아닙니다.")
        let anchorEnd = 4 + TrailerSceneEditor.frameMinimum
        XCTAssertEqual(TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 5)?.total ?? 0, 5, accuracy: 1e-3)
        XCTAssertGreaterThanOrEqual(scenes[0].length, anchorEnd - 1e-6, "문맥은 줄지만 앵커는 보이는 구간 안에 남습니다.")
        // 앵커 아래로는 못 줄이는 진짜 하한: 목표를 늘려 속이지 않고 앵커 끝이 실제 길이다.
        let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: 1)
        XCTAssertEqual(fit?.total ?? 0, anchorEnd, accuracy: 1e-3)
        XCTAssertEqual(scenes[0].adjustments?.keyframes.map(\.sourceTime), [4])
    }

    /// 아주 큰 디졸브가 이웃 길이의 절반으로 다시 잘리는 두 긴 클립도 짧은 목표에 네 번 반복으로 끝내지 않고 한 프레임 안에서 맞는다.
    func testLargeDissolveReclampStillReachesAShortTargetWithinOneFrame() {
        let sources = [videoSource(id: 1, duration: 120), videoSource(id: 2, duration: 120)]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 60), TrailerEditScene(id: 2, sourceID: 2, start: 0, length: 60)]
        TrailerSceneEditor.update(1, in: &scenes) { $0.adjustments = TrailerClipAdjustments(transition: TrailerTransition(dissolveDuration: 50)) }
        TrailerSceneEditor.update(2, in: &scenes) { $0.adjustments = TrailerClipAdjustments(rate: 1.5) }
        let before = scenes.map(\.adjustments)
        for target in [3.0, 0.5] {
            let fit = TrailerSceneEditor.fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: target)
            let actual = TrailerSceneEditor.outputBodyDuration(scenes)
            XCTAssertEqual(actual, target, accuracy: TrailerSceneEditor.frameMinimum + 1e-6, "실제 출력이 요청 \(target)초의 한 프레임 안입니다: \(actual)")
            XCTAssertEqual(fit?.total ?? 0, actual, accuracy: 1e-6, "반환 길이와 출력 시간표가 같습니다.")
            XCTAssertEqual(scenes.filter { !$0.excluded }.count, 2, "직접 편집한 두 장면은 빠지지 않습니다.")
        }
        XCTAssertEqual(scenes.map(\.adjustments), before, "배속·전환 값은 그대로입니다.")
    }

    /// 배속·디졸브만 있는 장면도 박자 맞춤이 출력 시간으로 움직이고, 저장된 배속·전환 값은 그대로다.
    func testBeatSyncMovesRateAndDissolveSceneInOutputTime() {
        let sources = [videoSource(id: 1, duration: 60), videoSource(id: 2, duration: 60)]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 8), TrailerEditScene(id: 2, sourceID: 2, start: 0, length: 4)]
        TrailerSceneEditor.update(1, in: &scenes) {
            $0.adjustments = TrailerClipAdjustments(rate: 2, transition: TrailerTransition(dissolveDuration: 1))
        }
        XCTAssertFalse(scenes[0].timingProtected, "배속·전환만으로는 창 전체가 잠기지 않습니다.")
        let rateBefore = scenes[0].adjustments?.rate, dissolveBefore = scenes[0].adjustments?.transition
        let result = TrailerSceneEditor.syncScenesToBeatOnsets(scenes: &scenes, sources: sources, beatOnsets: [0, 2, 4, 6], musicDuration: 8)
        let starts = TrailerSceneEditor.outputStarts(scenes)
        let cut = starts[2] ?? -1
        XCTAssertEqual((cut / 2).rounded(), cut / 2, accuracy: 1e-3, "다음 장면의 출력 시작이 박자에 닿습니다: \(cut)")
        XCTAssertGreaterThan(result.adjustedCount + (abs(cut - 3) > 0.02 ? 1 : 0), 0)
        XCTAssertEqual(scenes[0].adjustments?.rate, rateBefore)
        XCTAssertEqual(scenes[0].adjustments?.transition, dissolveBefore)
        XCTAssertEqual(TrailerSceneEditor.outputBodyDuration(scenes), cut + scenes[1].length, accuracy: 1e-6, "표시 길이와 출력 시간표가 같습니다.")
    }

    /// 마지막 장면↔마지막 화면 겹침과 다시 잘린 겹침까지 최종 시간표로 맞고, 선택 밖 장면과 저장된 값은 그대로다.
    func testBeatSyncUsesFinalMapWithOutroOverlapAndKeepsOutsideSelection() {
        let sources = [videoSource(id: 1, duration: 60), videoSource(id: 2, duration: 60), videoSource(id: 3, duration: 60)]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 4), TrailerEditScene(id: 2, sourceID: 2, start: 0, length: 0.5),
                      TrailerEditScene(id: 3, sourceID: 3, start: 0, length: 4)]
        TrailerSceneEditor.update(1, in: &scenes) { $0.adjustments = TrailerClipAdjustments(transition: TrailerTransition(dissolveDuration: 2)) }
        TrailerSceneEditor.update(3, in: &scenes) { $0.adjustments = TrailerClipAdjustments(transition: TrailerTransition(dissolveDuration: 1)) }
        let outsideBefore = scenes[1], dissolveBefore = scenes[2].adjustments?.transition
        let bodyBefore = TrailerSceneEditor.outputBodyDuration(scenes, outroLength: 2)
        let synced = TrailerSceneEditor.syncToBeatsWithMinimumRepeats(
            scenes: scenes, sources: sources, beatOnsets: [0, 2, 4, 6], music: TrailerMusicSelection(recordID: UUID(), name: "m", url: URL(fileURLWithPath: "/dummy"), duration: 8, policy: .loopMusic),
            cardsDuration: 2, introOffset: 0, outroDuration: 2, selectedIDs: [1, 3])
        XCTAssertEqual(synced.scenes[1], outsideBefore, "선택 밖 장면은 그대로입니다.")
        XCTAssertEqual(synced.scenes[2].adjustments?.transition, dissolveBefore, "저장된 전환 값은 그대로입니다.")
        XCTAssertEqual(TrailerSceneEditor.outputBodyDuration(synced.scenes, outroLength: 2), bodyBefore, accuracy: 0.05,
                       "본편 출력 길이(마지막 화면 겹침 포함)가 같습니다. 잔차: \(synced.result.fitResidual)")
    }

    /// 사진에 저장된 배속은 계획(미리보기·내보내기)과 예산이 같은 출력 길이를 낸다.
    func testPhotoStoredRateIsHonoredByPlanAndBudgetAlike() {
        let sources = [photoSource(id: 1)]
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 4)]
        TrailerSceneEditor.update(1, in: &scenes) { $0.adjustments = TrailerClipAdjustments(rate: 2) }
        let planned = TrailerPreparedPlan.manual(scenes, sources: sources)
        XCTAssertEqual(planned.first?.adjustments?.rate, 2)
        XCTAssertEqual(TrailerSceneEditor.outputBodyDuration(planned: planned), 2, accuracy: 1e-9)
        XCTAssertEqual(TrailerSceneEditor.outputBodyDuration(scenes), 2, accuracy: 1e-9)
        XCTAssertEqual(scenes[0].adjustments?.rate, 2, "저장된 값은 바뀌지 않습니다.")
    }

    /// 자동 생성 병합은 직접 편집 표시를 켜지 않고, 직접 고친 큐와 지운 구간은 그대로 둔다.
    func testGeneratedCueMergeDoesNotPromoteTheCaptionToManual() {
        var scenes = [TrailerEditScene(id: 1, sourceID: 1, start: 0, length: 10)]
        let manual = TrailerTimedCaptionCue(sourceID: 1, sourceStart: 1, sourceEnd: 2, text: "내 자막", origin: .manual, manuallyEdited: true)
        scenes[0].adjustments = TrailerClipAdjustments(cues: [manual], suppressions: [TrailerCueSuppression(sourceID: 1, sourceStart: 5, sourceEnd: 6)])
        let before = scenes[0].manual
        let generated = [TrailerTimedCaptionCue(sourceID: 1, sourceStart: 1.2, sourceEnd: 1.8, text: "겹침", origin: .generated),
                         TrailerTimedCaptionCue(sourceID: 1, sourceStart: 5, sourceEnd: 6, text: "지운 것", origin: .generated),
                         TrailerTimedCaptionCue(sourceID: 1, sourceStart: 8, sourceEnd: 9, text: "새 것", origin: .generated)]
        XCTAssertTrue(TrailerSceneEditor.mergeGeneratedCues(generated, intoSceneID: 1, in: &scenes))
        XCTAssertEqual(scenes[0].manual, before, "자동 병합은 자막 보호를 켜지 않습니다.")
        XCTAssertEqual(scenes[0].adjustments?.cues.map(\.text), ["내 자막", "새 것"])
        XCTAssertEqual(scenes[0].adjustments?.cues.first?.stableID, manual.stableID)
        XCTAssertFalse(TrailerSceneEditor.mergeGeneratedCues(generated, intoSceneID: 99, in: &scenes))
    }

    /// 음성 해설 파일은 프로젝트 사본으로 저장되고, 다시 열어도 복제해도 id·배치가 그대로이며, 저장이 실패해도 이미 저장된 파일은 남는다.
    func testVoiceoverFilesAreCommittedReopenedAndSurviveDuplicate() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("VoiceStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged", isDirectory: true)
        try files.createDirectory(at: staged, withIntermediateDirectories: true)
        let voiceFile = staged.appendingPathComponent("voice-test.m4a")
        try Data([1, 2, 3, 4]).write(to: voiceFile)
        let take = TrailerVoiceoverTake(relativeFile: "media/voice-test.m4a", outputStart: 2, sourceIn: 0.5, sourceOut: 6.5, volume: 1.5)
        let projectID = UUID()
        func record(_ takes: [TrailerVoiceoverTake]) -> TrailerProjectRecord {
            TrailerProjectRecord(
                id: projectID, customTitle: "t", mode: "trailer", createdAt: Date(), updatedAt: Date(), revision: 0,
                sources: [], nextSourceID: 0, removedSourceIDs: [], skippedSourceIDs: [], knownSourceIDs: [],
                photosAnalyzed: false, total: 10, clipLength: 4, aspectRatio: nil, music: nil, scenes: nil, nextSceneID: 1,
                selectedSceneID: nil, outputFile: nil, outputMode: nil, showedSettings: false, linkedCollectionVideoIDs: [],
                voiceovers: takes)
        }
        let saved = try TrailerProjectDisk.commit(
            TrailerProjectSnapshot(record: record([take]), stagedFiles: [:], musicFile: nil, outputFile: nil,
                                   voiceFiles: [take.stableID: voiceFile]), root: root)
        let folder = TrailerProjectDisk.folder(projectID, root: root)
        for escape in ["../x.m4a", "media/../../x.m4a", "/tmp/x.m4a", ""] {
            XCTAssertNil(TrailerProjectDisk.resolve(escape, in: folder), "프로젝트 폴더 밖 경로는 계속 거부됩니다: \(escape)")
        }
        let stored = try XCTUnwrap(TrailerProjectDisk.resolve(try XCTUnwrap(saved.voiceovers?.first).relativeFile, in: folder))
        XCTAssertEqual(try Data(contentsOf: stored), Data([1, 2, 3, 4]), "프로젝트가 소유한 사본입니다.")
        XCTAssertTrue(files.fileExists(atPath: voiceFile.path), "편집기의 원래 임시 파일은 건드리지 않습니다.")
        // 다시 열기
        let reopened = try XCTUnwrap(TrailerProjectDisk.load(folder: folder))
        XCTAssertEqual(reopened.voiceovers?.first?.stableID, take.stableID)
        XCTAssertEqual(reopened.voiceovers?.first?.outputStart, 2)
        XCTAssertEqual(reopened.voiceovers?.first?.volume ?? 0, 1.5, accuracy: 1e-9)
        // 임시 사본이 없어도 이전 저장의 사본으로 다시 저장된다.
        _ = try TrailerProjectDisk.commit(TrailerProjectSnapshot(record: record([take]), stagedFiles: [:], musicFile: nil, outputFile: nil), root: root)
        XCTAssertTrue(files.fileExists(atPath: stored.path))
        // 사본이 없는 새 해설을 넣은 저장은 실패하고 이미 저장된 파일은 그대로다.
        let orphan = TrailerVoiceoverTake(relativeFile: "media/voice-orphan.m4a", outputStart: 0, sourceIn: 0, sourceOut: 1)
        XCTAssertThrowsError(try TrailerProjectDisk.commit(
            TrailerProjectSnapshot(record: record([take, orphan]), stagedFiles: [:], musicFile: nil, outputFile: nil), root: root))
        XCTAssertTrue(files.fileExists(atPath: stored.path))
        XCTAssertEqual(TrailerProjectDisk.load(folder: folder)?.voiceovers?.map(\.stableID), [take.stableID])
        // 복제: 같은 id·배치, 복제본 폴더 안에 자기 사본이 있다.
        let copyID = UUID()
        let copy = try TrailerProjectDisk.duplicate(reopened, root: root, newID: copyID, title: "사본")
        XCTAssertEqual(copy.voiceovers?.first?.stableID, take.stableID)
        XCTAssertEqual(copy.voiceovers?.first?.sourceOut, 6.5)
        let copied = try XCTUnwrap(TrailerProjectDisk.resolve(try XCTUnwrap(copy.voiceovers?.first).relativeFile,
                                                              in: TrailerProjectDisk.folder(copyID, root: root)))
        XCTAssertEqual(try Data(contentsOf: copied), Data([1, 2, 3, 4]))
        XCTAssertTrue(files.fileExists(atPath: stored.path), "원본 프로젝트의 파일은 그대로입니다.")
    }
}
