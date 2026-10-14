import AVFoundation
import SwiftUI

enum TrailerMusicPolicy: String, CaseIterable, Identifiable {
    /// The video lasts exactly as long as the music.
    case fitMusic
    /// The video keeps its own length; the music repeats to fill it and stops with it.
    case loopMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fitMusic: "음악 길이에 맞추기"
        case .loopMusic: "음악 반복"
        }
    }
}

struct TrailerMusicSelection: Equatable {
    let recordID: UUID
    let name: String
    /// The PhoneHard original. It is only ever read, once, to copy it into the session.
    let url: URL
    let duration: Double
    var policy: TrailerMusicPolicy
}

enum TrailerMusicError: LocalizedError {
    case unreadable, tooShort, tooLong, tooManyRepeats

    var errorDescription: String? {
        switch self {
        case .unreadable: "이 음악 파일은 이 기기에서 재생할 수 없는 형식입니다. 다른 음악을 골라 주세요."
        case .tooShort: "음악이 1초보다 짧아 쓸 수 없습니다."
        case .tooLong: "1시간보다 긴 음악은 쓸 수 없습니다."
        case .tooManyRepeats: "음악과 영상 길이가 너무 달라 맞출 수 없습니다. 다른 음악이나 다른 맞춤 방식을 골라 주세요."
        }
    }

    var shortTitle: String {
        switch self {
        case .unreadable: "이 기기에서 쓸 수 없는 형식"
        case .tooShort: "1초보다 짧음"
        case .tooLong: "1시간보다 긺"
        case .tooManyRepeats: "길이를 맞출 수 없음"
        }
    }
}

enum TrailerMusic {
    static let minimumDuration = 1.0
    static let maximumDuration = 3_600.0
    /// Upper bound for how many times one music file is laid end to end.
    static let maximumRepeats = 600

    static func validate(duration: Double) throws {
        guard duration.isFinite, duration > 0 else { throw TrailerMusicError.unreadable }
        guard duration >= minimumDuration else { throw TrailerMusicError.tooShort }
        guard duration <= maximumDuration else { throw TrailerMusicError.tooLong }
    }

    /// Length of the file's own decodable audio track. Being recognized as audio by
    /// name or type is not enough; this is what decides whether it can be used.
    static func usableDuration(of url: URL) async throws -> Double {
        let seconds: Double
        do {
            // The same precise timing the export asks for, so the length shown in the
            // picker is the length the video is fitted to.
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  try await track.load(.isDecodable) else { throw TrailerMusicError.unreadable }
            seconds = try await track.load(.timeRange).duration.seconds
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TrailerMusicError.unreadable
        }
        try validate(duration: seconds)
        return seconds
    }
}

/// Turns the measured loudness of the original clips into volume changes for the music
/// track only: quieter while the original sound is audible, louder over silence, photos
/// and clips without sound. The original audio's own level is never touched.
///
/// The levels and timings below are chosen values, not ones tuned by listening on a device.
enum TrailerMusicDucking {
    static let loudVolume: Float = 0.65
    static let quietVolume: Float = 0.18
    /// About -40 dBFS: above typical room noise, below ordinary speech.
    static let audibleRMS: Float = 0.01
    static let attack = 0.1
    static let release = 0.3
    /// Pauses shorter than this stay ducked, so the music does not pump between words.
    /// Must stay at least `attack + release` so two ramps can never overlap.
    static let bridge = 0.5
    /// A single loud bin (a click) is not worth a volume change.
    static let minimumSound = 0.15

    /// One stretch of original audio actually placed in the output.
    struct Clip {
        let outputStart: Double
        let sourceStart: Double
        let length: Double
        /// nil when the sound could not be measured; the whole stretch then counts as
        /// audible so the original is never drowned out.
        let envelope: AudioActivityEnvelope?
    }

    struct Ramp {
        let start: Double
        let end: Double
        let from: Float
        let to: Float
    }

    /// Output-timeline ranges where the original sound is audible, in order.
    static func audibleIntervals(clips: [Clip]) -> [(start: Double, end: Double)] {
        var runs: [(start: Double, end: Double)] = []
        func add(_ start: Double, _ end: Double) {
            guard end > start else { return }
            if let last = runs.last, start - last.end < 0.001 {
                runs[runs.count - 1].end = max(last.end, end)
            } else {
                runs.append((start, end))
            }
        }
        for clip in clips.sorted(by: { $0.outputStart < $1.outputStart }) where clip.length > 0 {
            guard let envelope = clip.envelope else {
                add(clip.outputStart, clip.outputStart + clip.length)
                continue
            }
            guard envelope.binDuration > 0, !envelope.rms.isEmpty else { continue }
            let sourceEnd = clip.sourceStart + clip.length
            let first = max(0, Int((clip.sourceStart / envelope.binDuration).rounded(.down)))
            let last = min(envelope.rms.count - 1, Int((sourceEnd / envelope.binDuration).rounded(.down)))
            guard first <= last else { continue }
            for bin in first...last where envelope.rms[bin] >= audibleRMS {
                let start = max(clip.sourceStart, Double(bin) * envelope.binDuration)
                let end = min(sourceEnd, Double(bin + 1) * envelope.binDuration)
                add(clip.outputStart + start - clip.sourceStart, clip.outputStart + end - clip.sourceStart)
            }
        }
        var merged: [(start: Double, end: Double)] = []
        for run in runs where run.end - run.start >= minimumSound {
            if let last = merged.last, run.start - last.end < bridge {
                merged[merged.count - 1].end = max(last.end, run.end)
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    /// Back-to-back, non-overlapping ramps covering `0...total` for the one music track.
    static func ramps(audible: [(start: Double, end: Double)], total: Double) -> [Ramp] {
        guard total > 0 else { return [] }
        var points: [(time: Double, volume: Float)] = [(0, loudVolume)]
        for interval in audible {
            let start = min(total, max(0, interval.start))
            let end = min(total, interval.end)
            guard end > start else { continue }
            let down = max(points[points.count - 1].time, start - attack)
            if start <= 0 {
                points = [(0, quietVolume)]
            } else {
                points.append((down, loudVolume))
                points.append((max(down, start), quietVolume))
            }
            points.append((end, quietVolume))
            points.append((min(total, end + release), loudVolume))
        }
        points.append((total, points[points.count - 1].volume))
        var result: [Ramp] = []
        for (from, to) in zip(points, points.dropFirst()) where to.time - from.time > 0.001 {
            result.append(Ramp(start: from.time, end: to.time, from: from.volume, to: to.volume))
        }
        return result
    }
}

/// Plays at most one audition track at a time, strictly for previewing a candidate
/// music file before it is chosen; it never touches the trailer export's own audio.
final class TrailerMusicAuditionPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// A PhoneHard record's UUID string or a remote item's id; the two never collide.
    @Published private(set) var playingID: String?
    /// Why the last audition did not play, shown to the user until dismissed.
    @Published var failure: String?

    private var player: AVAudioPlayer?

    func toggle(id: String, url: URL) {
        if playingID == id {
            stop()
            return
        }
        stop()
        failure = nil
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: url)
        } catch {
            fail("이 음악 파일을 열 수 없습니다.", error: error)
            return
        }
        player.delegate = self
        // A player that did not start is dropped here; it was never kept.
        guard player.play() else {
            fail("이 음악 파일을 재생하지 못했습니다.", error: nil)
            return
        }
        self.player = player
        playingID = id
    }

    /// Stops whatever was playing and reports why; the code identifies a system error.
    func fail(_ message: String, error: Error?) {
        stop()
        guard let error = error as NSError? else {
            failure = message
            return
        }
        failure = "\(message) (\(error.domain) \(error.code))"
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard self?.player === player else { return }
            self?.stop()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let code = (error as NSError?).map { " (\($0.domain) \($0.code))" } ?? ""
        DispatchQueue.main.async { [weak self] in
            guard self?.player === player else { return }
            self?.stop()
            self?.failure = "재생 중에 이 음악 파일을 읽지 못했습니다.\(code)"
        }
    }
}

/// Where the music picker is looking for music.
private enum TrailerMusicLocation: String, CaseIterable, Identifiable {
    case phoneHard, network, favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .phoneHard: "폰하드"
        case .network: "네트워크"
        case .favorites: "즐겨찾기"
        }
    }
}

/// Picks one of the audio files in PhoneHard's Music folder (nested folders included)
/// for the video, or none. Audio stored anywhere else in PhoneHard is left as it is and
/// simply not listed. Music on a saved connection or in a favorite folder can be fetched
/// to listen to, and lands in the Music folder only once it is actually used. Opening
/// the in-app browser from here is a nested presentation, and remote folders are pushed
/// inside this picker, so the editor underneath and its session stay alive.
struct TrailerMusicPickerView: View {
    let currentID: UUID?
    let policy: TrailerMusicPolicy
    let onPick: (TrailerMusicSelection?) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @State private var durations: [UUID: Double] = [:]
    @State private var unusable: [UUID: String] = [:]
    @State private var showingBrowser = false
    @State private var downloadedID: UUID?
    @State private var location = TrailerMusicLocation.phoneHard
    @StateObject private var audition = TrailerMusicAuditionPlayer()
    @StateObject private var remote = TrailerMusicRemoteLoader()

    private var audioRecords: [SharedInboxRecord] {
        inboxStore.records.filter { Self.isStoredInMusicFolder($0) && LocalInboxFileService.remoteItem(for: $0).isAudio }
    }

    /// `Music/…` at any depth, by the record's own stored path. Where that path really
    /// resolves to is checked once per record in `measureDurations`.
    private static func isStoredInMusicFolder(_ record: SharedInboxRecord) -> Bool {
        let components = record.storedFilename.split(separator: "/", omittingEmptySubsequences: false)
        return components.count >= 2 && components[0] == SharedInbox.musicDirectoryName
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        remote.reset()
                        onPick(nil)
                        dismiss()
                    } label: {
                        row(title: "음악 없음", detail: nil, selected: currentID == nil)
                    }
                    .buttonStyle(.plain)
                    .disabled(remote.isImporting)
                }
                Section {
                    Picker("음악 위치", selection: $location) {
                        ForEach(TrailerMusicLocation.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                switch location {
                case .phoneHard:
                    phoneHardSections
                case .network:
                    Section {
                        TrailerMusicNetworkRows(loader: remote, audition: audition)
                    } header: {
                        Text("네트워크")
                            .font(MacUIScale.sectionNoteFont)
                    } footer: {
                        Text(remoteFooter)
                            .font(MacUIScale.sectionNoteFont)
                    }
                case .favorites:
                    Section {
                        TrailerMusicFavoriteRows(loader: remote, audition: audition)
                    } header: {
                        Text("즐겨찾기 폴더")
                            .font(MacUIScale.sectionNoteFont)
                    } footer: {
                        Text(remoteFooter)
                            .font(MacUIScale.sectionNoteFont)
                    }
                }
            }
            .navigationTitle("음악 선택").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Group {
                        Button("닫기") { remote.reset(); dismiss() }
                            .disabled(remote.isImporting)
                    }
                    .uiBarFont()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let active = remote.active {
                TrailerMusicDownloadBanner(active: active) { remote.cancel() }
            }
        }
        .task(id: audioRecords.map(\.id)) { await measureDurations() }
        .fullScreenCover(isPresented: $showingBrowser) {
            WebBrowserView(onMusicSaved: { downloadedID = $0.id })
        }
        .interactiveDismissDisabled(remote.isImporting)
        .onAppear { remote.attach(audition: audition, inboxStore: inboxStore) }
        .onDisappear { remote.reset() }
        .onChange(of: remote.selection) { _, selection in
            guard var selection else { return }
            selection.policy = policy
            remote.reset()
            onPick(selection)
            dismiss()
        }
        .alert(audition.failure != nil ? "미리듣기를 할 수 없습니다" : "음악을 가져올 수 없습니다",
               isPresented: Binding(get: { audition.failure != nil || remote.failure != nil },
                                    set: { if !$0 { audition.failure = nil; remote.failure = nil } })) {
            Button("확인", role: .cancel) { }
        } message: {
            Text(audition.failure ?? remote.failure ?? "")
        }
    }

    private var remoteFooter: String {
        "미리듣기와 사용은 음악을 모두 받은 뒤에 됩니다. 사용을 누른 음악만 폰하드 Music 폴더에 저장되고, 서버의 원본은 바뀌지 않습니다."
    }

    @ViewBuilder
    private var phoneHardSections: some View {
        Section {
            if audioRecords.isEmpty {
                Text("폰하드 Music 폴더에 음악 파일이 없습니다.")
                    .font(.ui(.footnote)).foregroundStyle(.secondary)
            }
            ForEach(audioRecords) { record in
                HStack(spacing: ui(10)) {
                    auditionButton(for: record)
                    Button { pick(record) } label: {
                        row(title: record.originalFilename, detail: detail(for: record),
                            selected: currentID == record.id)
                    }
                    .buttonStyle(.plain)
                    .disabled(durations[record.id] == nil)
                    .accessibilityValue(detail(for: record))
                }
            }
        } header: {
            Text("폰하드 음악")
                .font(MacUIScale.sectionNoteFont)
        } footer: {
            Text("폰하드 Music 폴더와 그 안의 폴더에 있는 음악만 보여줍니다. 원본은 바뀌지 않습니다.")
                .font(MacUIScale.sectionNoteFont)
        }
        Section {
            Button("브라우저에서 음악 받기", systemImage: "globe") {
                audition.stop()
                showingBrowser = true
            }
        } footer: {
            Text("받은 음악은 폰하드 Music 폴더에 저장됩니다.")
                .font(MacUIScale.sectionNoteFont)
        }
    }

    @ViewBuilder
    private func auditionButton(for record: SharedInboxRecord) -> some View {
        let isPlaying = audition.playingID == record.id.uuidString
        Button {
            do {
                audition.toggle(id: record.id.uuidString, url: try SharedInbox.fileURL(for: record))
            } catch {
                audition.fail("이 음악 파일을 찾을 수 없습니다.", error: nil)
            }
        } label: {
            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                .font(.ui(.title3))
                .foregroundStyle(durations[record.id] == nil ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(durations[record.id] == nil)
        .accessibilityLabel(isPlaying ? "미리듣기 정지" : "미리듣기 재생")
    }

    private func row(title: String, detail: String?, selected: Bool) -> some View {
        HStack(spacing: ui(10)) {
            VStack(alignment: .leading, spacing: ui(2)) {
                Text(title).lineLimit(2)
                if let detail {
                    Text(detail).font(.ui(.caption)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: ui(8))
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
        .contentShape(Rectangle())
    }

    private func detail(for record: SharedInboxRecord) -> String {
        let length = durations[record.id].map(videoTrailerTime) ?? unusable[record.id] ?? "확인 중…"
        return record.id == downloadedID ? "\(length) · 방금 받음" : length
    }

    private func pick(_ record: SharedInboxRecord) {
        guard let duration = durations[record.id], let url = try? SharedInbox.fileURL(for: record) else { return }
        remote.reset()
        onPick(TrailerMusicSelection(recordID: record.id, name: record.originalFilename, url: url,
                                     duration: duration, policy: policy))
        dismiss()
    }

    private func measureDurations() async {
        let musicRoot = (try? SharedInbox.storageURL())?
            .appendingPathComponent(SharedInbox.musicDirectoryName, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        for record in audioRecords where durations[record.id] == nil && unusable[record.id] == nil {
            guard let url = try? SharedInbox.fileURL(for: record) else {
                unusable[record.id] = "파일을 찾을 수 없음"
                continue
            }
            // The validated location itself must be inside the Music folder, not only
            // the stored name; such a row stays disabled for both audition and picking.
            guard let musicRoot, url.path.hasPrefix(musicRoot + "/") else {
                unusable[record.id] = "Music 폴더 밖의 파일"
                continue
            }
            do {
                durations[record.id] = try await TrailerMusic.usableDuration(of: url)
            } catch is CancellationError {
                return
            } catch {
                unusable[record.id] = (error as? TrailerMusicError)?.shortTitle ?? TrailerMusicError.unreadable.shortTitle
            }
            if Task.isCancelled { return }
        }
    }
}
