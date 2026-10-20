import AVFoundation
import SwiftUI

enum TrailerMusicPolicy: String, CaseIterable, Identifiable {
    /// The video lasts exactly as long as the music.
    case fitMusic
    /// The video keeps its own length; the music repeats to fill it and stops with it.
    case loopMusic
    /// The user set the video's length by hand: the music plays once from the start and
    /// is cut where the video ends; a longer video goes on with its own sound only.
    case single

    var id: String { rawValue }

    /// The two automatic policies offered as buttons. `single` is never offered: it is
    /// what is left when the user changes the total length and neither applies any more.
    static let selectable: [TrailerMusicPolicy] = [.fitMusic, .loopMusic]

    var title: String {
        switch self {
        case .fitMusic: Self.fitTitle(count: 1)
        case .loopMusic: "음악 반복"
        case .single: "음악 한 번"
        }
    }

    /// "음악 길이에 맞추기", then "두 번 맞추기", "세 번", "네 번" and "5번" onwards.
    static func fitTitle(count: Int) -> String {
        switch count {
        case ...1: "음악 길이에 맞추기"
        case 2: "음악 길이에 두 번 맞추기"
        case 3: "음악 길이에 세 번 맞추기"
        case 4: "음악 길이에 네 번 맞추기"
        default: "음악 길이에 \(count)번 맞추기"
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
    /// How many times the music is laid end to end when the video is fitted to it.
    /// Only `fitMusic` reads it; it is 1 under every other policy.
    var fitCount = 1
    /// "배경음악 자동 조절": on follows the original sound, off keeps the music at its normal level.
    var autoDuck = true
    /// 배경음악 음량 배율(0...1). 원본 소리 음량과 따로 정하고, 자동 조절 결과에 곱한다.
    var level = 1.0

    /// The length a fitted video comes to: the music's own length times `fitCount`.
    var fittedDuration: Double { duration * Double(max(1, fitCount)) }
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

/// Some files named .mp3 are really a RIFF/WAVE wrapper (format tag 0x0055) around plain
/// MPEG audio frames, which the system players refuse. This copies only the wrapper's
/// data chunk into a new MP3 file beside the staged copy it is given; nothing else is touched.
enum WAVEMPEGUnwrapper {
    /// The unwrapped file, or nil when `url` is not such a wrapper (or is malformed).
    static func unwrappedCopy(of url: URL) -> URL? {
        guard let input = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? input.close() }
        guard let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil,
              let range = mpegDataRange(in: input, fileSize: fileSize) else { return nil }
        let destination = url.deletingPathExtension().appendingPathExtension("unwrapped.mp3")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination) else { return nil }
        defer { try? output.close() }
        do {
            try input.seek(toOffset: range.lowerBound)
            var remaining = range.upperBound - range.lowerBound
            while remaining > 0 {
                guard let chunk = try input.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
            guard remaining == 0 else { throw CocoaError(.fileReadCorruptFile) }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }

    /// Byte range of the `data` chunk when the header proves WAVE with the MPEG Layer 3 tag
    /// and the data starts with an MPEG frame sync or an ID3 tag. A declared size past the
    /// end of the file is cut to the file.
    private static func mpegDataRange(in input: FileHandle, fileSize: UInt64) -> Range<UInt64>? {
        func read(_ count: Int, at offset: UInt64) -> Data? {
            guard offset + UInt64(count) <= fileSize, (try? input.seek(toOffset: offset)) != nil,
                  let data = try? input.read(upToCount: count), data.count == count else { return nil }
            return data
        }
        func littleEndian(_ data: Data, _ start: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | UInt64(data[data.startIndex + start + $1]) << UInt64(8 * $1) }
        }
        guard let header = read(12, at: 0), header.prefix(4) == Data("RIFF".utf8),
              header.suffix(4) == Data("WAVE".utf8) else { return nil }
        var offset: UInt64 = 12
        var isMPEG = false
        while let chunk = read(8, at: offset) {
            let size = littleEndian(chunk, 4, 4)
            let body = offset + 8
            let identifier = String(decoding: chunk.prefix(4), as: UTF8.self)
            if identifier == "fmt " {
                guard size >= 2, let tag = read(2, at: body) else { return nil }
                isMPEG = littleEndian(tag, 0, 2) == 0x0055
            } else if identifier == "data" {
                guard isMPEG, body < fileSize else { return nil }
                let end = min(fileSize, body + size)
                guard end > body, let start = read(3, at: body) else { return nil }
                let isSync = start[start.startIndex] == 0xFF && start[start.startIndex + 1] & 0xE0 == 0xE0
                guard isSync || start == Data("ID3".utf8) else { return nil }
                return body..<end
            }
            // Chunks are padded to an even length.
            offset = body + size + (size & 1)
        }
        return nil
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
        let seconds = try await measuredDuration(of: url)
        try validate(duration: seconds)
        return seconds
    }

    /// Length of the file's audio track without the trailer's length limits.
    static func measuredDuration(of url: URL) async throws -> Double {
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
        return seconds
    }
}

/// Turns the measured loudness of the original clips into a continuous volume curve for
/// the music track only: the louder the original sound is at that moment of the output,
/// the quieter the music; soft or silent stretches (and photos) bring it back up. The
/// original audio's own level is never touched.
///
/// The levels and timings below are chosen values, not ones tuned by listening on a device.
enum TrailerMusicDucking {
    static let loudVolume: Float = 0.65
    static let quietVolume: Float = 0.18
    /// Original RMS at or below this (about -55 dBFS) leaves the music at full level.
    static let silentDB: Float = -55
    /// Original RMS at or above this (about -25 dBFS, clearly audible speech) ducks fully.
    static let loudDB: Float = -25
    /// Time constants of the smoothing: quick to step back, slow to come up again.
    static let attack = 0.1
    static let release = 0.4
    /// Resolution of the curve on the output timeline.
    static let step = 0.1

    /// One stretch of original audio actually placed in the output.
    struct Clip {
        let outputStart: Double
        let sourceStart: Double
        let length: Double
        /// nil when the sound could not be measured; the whole stretch then counts as
        /// loud so the original is never drowned out.
        let envelope: AudioActivityEnvelope?
    }

    struct Ramp {
        let start: Double
        let end: Double
        let from: Float
        let to: Float
    }

    private static func gain(forRMS rms: Float) -> Float {
        let db = rms > 0 ? 20 * log10(rms) : -.infinity
        let amount = min(1, max(0, (db - silentDB) / (loudDB - silentDB)))
        return loudVolume + (quietVolume - loudVolume) * amount
    }

    /// Volume ramps for the one music track covering `0...total` of the output timeline.
    /// Each output step takes the loudest original sound placed in it, so offsets, photos
    /// and clips without sound (nothing placed) are measured where they really land.
    static func ramps(clips: [Clip], total: Double, enabled: Bool = true) -> [Ramp] {
        guard total > 0, enabled else { return [] }
        let count = Int((total / step).rounded(.up))
        var level = [Float](repeating: 0, count: count + 1)
        func raise(_ rms: Float, from start: Double, to end: Double) {
            guard end > start else { return }
            let first = max(0, Int((start / step).rounded(.down)))
            let last = min(count - 1, Int((end / step).rounded(.up)) - 1)
            guard first <= last else { return }
            for index in first...last { level[index] = max(level[index], rms) }
        }
        for clip in clips where clip.length > 0 {
            guard let envelope = clip.envelope else {
                raise(1, from: clip.outputStart, to: clip.outputStart + clip.length)
                continue
            }
            guard envelope.binDuration > 0, !envelope.rms.isEmpty else { continue }
            let sourceEnd = clip.sourceStart + clip.length
            let first = max(0, Int((clip.sourceStart / envelope.binDuration).rounded(.down)))
            let last = min(envelope.rms.count - 1, Int((sourceEnd / envelope.binDuration).rounded(.down)))
            guard first <= last else { continue }
            for bin in first...last {
                let start = max(clip.sourceStart, Double(bin) * envelope.binDuration)
                let end = min(sourceEnd, Double(bin + 1) * envelope.binDuration)
                raise(envelope.rms[bin], from: clip.outputStart + start - clip.sourceStart,
                      to: clip.outputStart + end - clip.sourceStart)
            }
        }
        // Looking one step ahead lets the music already be going down as the sound starts.
        let attackBlend = Float(1 - exp(-step / attack))
        let releaseBlend = Float(1 - exp(-step / release))
        var gains = [Float](repeating: loudVolume, count: count + 1)
        gains[0] = min(gain(forRMS: level[0]), gain(forRMS: level[1]))
        for index in 1...count {
            let target = min(gain(forRMS: level[index]), gain(forRMS: level[min(count, index + 1)]))
            let blend = target < gains[index - 1] ? attackBlend : releaseBlend
            gains[index] = gains[index - 1] + (target - gains[index - 1]) * blend
        }
        var result: [Ramp] = []
        var held = gains[0]
        for index in 0..<count {
            let end = min(total, Double(index + 1) * step)
            let start = Double(index) * step
            guard end - start > 0.001 else { continue }
            // Flat stretches are left to hold the last value, which keeps the mix small.
            guard index == 0 || abs(gains[index + 1] - held) > 0.002 else { continue }
            result.append(Ramp(start: start, end: end, from: index == 0 ? gains[0] : gains[index], to: gains[index + 1]))
            held = gains[index + 1]
        }
        return result
    }
}

/// Plays at most one audition track at a time, strictly for previewing a candidate
/// music file before it is chosen; it never touches the trailer export's own audio.
@MainActor
final class TrailerMusicAuditionPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// A PhoneHard record's UUID string or a remote item's id; the two never collide.
    @Published private(set) var playingID: String?
    /// Why the last audition did not play, shown to the user until dismissed.
    @Published var failure: String?
    /// 0...1 of the playing track; only the inline list control reads it.
    @Published private(set) var progress = 0.0
    /// Seconds played and the track's own length, for the list's time text.
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPaused = false

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

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
        SharedMediaAudioSession.activatePlayback()
        // A player that did not start is dropped here; it was never kept.
        guard player.play() else {
            fail("이 음악 파일을 재생하지 못했습니다.", error: nil)
            return
        }
        self.player = player
        playingID = id
        duration = player.duration
        startProgressTimer()
    }

    /// Pauses the track that is playing, or continues it from where it stopped.
    func pauseOrResume() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPaused = true
            progressTimer?.invalidate()
        } else if player.play() {
            isPaused = false
            startProgressTimer()
        } else {
            fail("이 음악 파일을 재생하지 못했습니다.", error: nil)
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.progress = min(1, player.currentTime / player.duration)
                self.elapsed = player.currentTime
            }
        }
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
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        playingID = nil
        progress = 0
        elapsed = 0
        duration = 0
        isPaused = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let current = self?.player, ObjectIdentifier(current) == finished else { return }
            self?.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let code = (error as NSError?).map { " (\($0.domain) \($0.code))" } ?? ""
        let failed = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let current = self?.player, ObjectIdentifier(current) == failed else { return }
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

    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
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
            guard let selection else { return }
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
                    .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
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
                    Text(detail).font(.ui(.caption)).foregroundStyle(PorcelainMetrics.secondary).monospacedDigit()
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
                                     duration: duration, policy: .loopMusic))
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
