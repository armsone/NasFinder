import AVFAudio
import AVFoundation
import Darwin
import Foundation
import Speech

// MARK: - Resource Identity Helper

private struct ResourceIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

private func queryResourceIdentity(for url: URL) -> ResourceIdentity? {
    var st = stat()
    // Using lstat so symbolic links are inspected directly rather than followed
    guard lstat(url.path, &st) == 0 else { return nil }
    return ResourceIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino))
}

private func isSymbolicLink(at url: URL) -> Bool {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return false }
    return (st.st_mode & S_IFMT) == S_IFLNK
}

// MARK: - Voiceover Artifact & Errors

/// Immutable artifact describing a completed, finalized voiceover recording.
struct TrailerVoiceoverArtifact: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let duration: Double

    init(id: UUID = UUID(), url: URL, duration: Double) {
        self.id = id
        self.url = url
        self.duration = max(0.0, duration.isFinite ? duration : 0.0)
    }
}

/// Typed errors produced during voiceover recording lifecycle.
enum TrailerVoiceoverError: LocalizedError, Equatable, Sendable {
    case missingPrivacyDescription
    case permissionDenied
    case unsupportedPlatform
    case invalidParentDirectory(String)
    case fileCreationFailed(String)
    case preparationFailed(recoveryURL: URL?)
    case startFailed(reason: String, recoveryURL: URL?)
    case recordingFailed(reason: String, recoveryURL: URL?)
    case audioFinalizationFailed(reason: String, recoveryURL: URL?)
    case pendingArtifact(recoveryURL: URL?)
    case busy(String)
    case alreadyRecording
    case notRecording
    case cancelled

    var recoveryURL: URL? {
        switch self {
        case .preparationFailed(let url),
             .startFailed(_, let url),
             .recordingFailed(_, let url),
             .audioFinalizationFailed(_, let url),
             .pendingArtifact(let url):
            return url
        default:
            return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingPrivacyDescription:
            return "NSMicrophoneUsageDescription이 Info.plist에 설정되지 않았습니다."
        case .permissionDenied:
            return "마이크 사용 권한이 거부되었습니다."
        case .unsupportedPlatform:
            return "현재 플랫폼 버전에서는 보이스오버 녹음이 지원되지 않습니다 (macOS 14.0+, iOS 17.0+ 필요)."
        case .invalidParentDirectory(let reason):
            return "보이스오버 저장 디렉터리가 유효하지 않습니다: \(reason)"
        case .fileCreationFailed(let reason):
            return "녹음 대상 파일 생성에 실패했습니다: \(reason)"
        case .preparationFailed:
            return "오디오 녹음기 준비(prepareToRecord)에 실패했습니다."
        case .startFailed(let reason, _):
            return "오디오 녹음 시작에 실패했습니다: \(reason)"
        case .recordingFailed(let reason, _):
            return "오디오 녹음 중 오류가 발생했습니다: \(reason)"
        case .audioFinalizationFailed(let reason, _):
            return "녹음 파일 확정 및 재생 시간 계산에 실패했습니다: \(reason)"
        case .pendingArtifact:
            return "이전 녹음 산출물이 아직 완료 또는 해제되지 않았습니다."
        case .busy(let reason):
            return "녹음기가 작업 중입니다: \(reason)"
        case .alreadyRecording:
            return "이미 녹음이 진행 중입니다."
        case .notRecording:
            return "진행 중인 녹음이 없습니다."
        case .cancelled:
            return "보이스오버 녹음이 취소되었습니다."
        }
    }
}

// MARK: - Voiceover Recorder State

/// Observable state transitions of the voiceover recorder.
enum TrailerVoiceoverRecorderState: Equatable, Sendable {
    case idle
    case requesting(requestID: UUID)
    case recording(requestID: UUID, fileURL: URL)
    case stopping(requestID: UUID, fileURL: URL)
    case ready(TrailerVoiceoverArtifact)
    case error(TrailerVoiceoverError)
}

// MARK: - Voiceover Recorder Controller

/// MainActor controller managing voiceover capture via native AVAudioRecorder.
///
/// Availability: macOS 14.0+, iOS 17.0+, macCatalyst 17.0+ using modern AVAudioApplication permission.
/// Explicit caller shutdown via `handleViewCloseOrShutdown()` is required before release.
@available(macOS 14.0, iOS 17.0, macCatalyst 17.0, *)
@MainActor
final class TrailerVoiceoverRecorder {
    private(set) var state: TrailerVoiceoverRecorderState = .idle
    private(set) var lastRecoveryURL: URL?

    private var activeGeneration: Int = 0
    private var activeRequestID: UUID?
    private var canonicalParentURL: URL?
    private var currentFolderURL: URL?
    private var currentFolderIdentity: ResourceIdentity?
    private var currentFileURL: URL?
    private var currentFileIdentity: ResourceIdentity?
    private var isCommitted: Bool = false
    private var recordedArtifact: TrailerVoiceoverArtifact?

    private var recorder: AVAudioRecorder?
    private var recorderDelegateBridge: RecorderDelegateBridge?
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    private var stopContinuation: CheckedContinuation<TrailerVoiceoverArtifact, any Error>?

    #if os(iOS) || targetEnvironment(macCatalyst)
    private struct SavedAudioSessionState {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }
    private var savedAudioSession: SavedAudioSessionState?
    nonisolated(unsafe) private var interruptionObserver: (any NSObjectProtocol)?
    #endif

    init() {
        // Init does not trigger hardware capture, permission requests, or disk writes.
    }

    deinit {
        // Best-effort cleanup. Normal explicit shutdown via handleViewCloseOrShutdown()
        // is the documented caller requirement before deallocating controller instances.
        recorder?.stop()
        #if os(iOS) || targetEnvironment(macCatalyst)
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    // MARK: - Recording Lifecycle

    /// Begins voiceover recording inside a dedicated private subfolder of parentURL.
    ///
    /// - Parameter parentURL: Valid caller-owned parent directory.
    /// - Throws: `TrailerVoiceoverError` on validation, privacy, permission, or hardware setup failure.
    func startRecording(in parentURL: URL) async throws {
        switch state {
        case .requesting, .recording, .stopping:
            throw TrailerVoiceoverError.alreadyRecording
        case .ready(let artifact):
            if !isCommitted {
                throw TrailerVoiceoverError.pendingArtifact(recoveryURL: artifact.url)
            }
            try await performStart(in: parentURL)
        case .error(let error):
            if !isCommitted, let pendingURL = error.recoveryURL ?? lastRecoveryURL ?? currentFileURL {
                throw TrailerVoiceoverError.pendingArtifact(recoveryURL: pendingURL)
            }
            try await performStart(in: parentURL)
        case .idle:
            if !isCommitted, let pendingURL = recordedArtifact?.url ?? lastRecoveryURL ?? currentFileURL {
                throw TrailerVoiceoverError.pendingArtifact(recoveryURL: pendingURL)
            }
            try await performStart(in: parentURL)
        }
    }

    private func performStart(in parentURL: URL) async throws {
        // 1. Validate canonical parent directory: resolve symlinks, verify non-root and minimum depth
        let canonicalParent = parentURL.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalParent.isFileURL else {
            let error = TrailerVoiceoverError.invalidParentDirectory("URL must be a file URL.")
            state = .error(error)
            throw error
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalParent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            let error = TrailerVoiceoverError.invalidParentDirectory("Parent directory does not exist or is not a directory.")
            state = .error(error)
            throw error
        }
        let parentComponents = canonicalParent.pathComponents
        guard canonicalParent.path != "/", parentComponents.count >= 2 else {
            let error = TrailerVoiceoverError.invalidParentDirectory("Parent directory must be non-root and have valid directory depth.")
            state = .error(error)
            throw error
        }
        guard !isSymbolicLink(at: canonicalParent) else {
            let error = TrailerVoiceoverError.invalidParentDirectory("Parent directory resolved to a symbolic link.")
            state = .error(error)
            throw error
        }

        // 2. Pre-flight privacy description check BEFORE framework call to prevent SDK abort
        guard let usageDescription = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String,
              !usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let error = TrailerVoiceoverError.missingPrivacyDescription
            state = .error(error)
            throw error
        }

        // 3. Setup request tracking & generation
        activeGeneration += 1
        let generation = activeGeneration
        let requestID = UUID()
        activeRequestID = requestID
        isCommitted = false
        recordedArtifact = nil
        lastRecoveryURL = nil
        state = .requesting(requestID: requestID)

        // 4. Request microphone authorization via AVAudioApplication with cooperative cancellation support
        guard !Task.isCancelled else {
            state = .idle
            throw TrailerVoiceoverError.cancelled
        }

        let permissionGranted = await requestMicrophonePermission(generation: generation)
        guard activeGeneration == generation else {
            throw TrailerVoiceoverError.cancelled
        }
        guard !Task.isCancelled else {
            state = .idle
            throw TrailerVoiceoverError.cancelled
        }
        guard permissionGranted else {
            let error = TrailerVoiceoverError.permissionDenied
            state = .error(error)
            throw error
        }

        // 5. iOS/Catalyst session setup: save original state, configure playAndRecord, activate
        #if os(iOS) || targetEnvironment(macCatalyst)
        do {
            try configureAndActivateAudioSession()
        } catch {
            let voiceoverError = TrailerVoiceoverError.startFailed(reason: "Audio session activation failed: \(error.localizedDescription)", recoveryURL: nil)
            state = .error(voiceoverError)
            throw voiceoverError
        }
        #endif

        // 6. Setup dedicated unique folder (0700) with no intermediate-directory reuse
        let folderName = "Voiceover-\(requestID.uuidString)"
        let dedicatedFolder = canonicalParent.appendingPathComponent(folderName, isDirectory: true)

        guard !FileManager.default.fileExists(atPath: dedicatedFolder.path) else {
            #if os(iOS) || targetEnvironment(macCatalyst)
            restoreAndDeactivateAudioSession()
            #endif
            let voiceoverError = TrailerVoiceoverError.fileCreationFailed("Dedicated folder already exists.")
            state = .error(voiceoverError)
            throw voiceoverError
        }

        do {
            try FileManager.default.createDirectory(
                at: dedicatedFolder,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            #if os(iOS) || targetEnvironment(macCatalyst)
            restoreAndDeactivateAudioSession()
            #endif
            let voiceoverError = TrailerVoiceoverError.fileCreationFailed("Failed to create dedicated folder: \(error.localizedDescription)")
            state = .error(voiceoverError)
            throw voiceoverError
        }

        let canonicalFolder = dedicatedFolder.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalFolder.deletingLastPathComponent().path == canonicalParent.path,
              canonicalFolder.lastPathComponent == folderName,
              !isSymbolicLink(at: canonicalFolder),
              let folderIdentity = queryResourceIdentity(for: canonicalFolder) else {
            lastRecoveryURL = dedicatedFolder
            #if os(iOS) || targetEnvironment(macCatalyst)
            restoreAndDeactivateAudioSession()
            #endif
            let voiceoverError = TrailerVoiceoverError.fileCreationFailed("Failed to verify dedicated folder identity or ownership.")
            state = .error(voiceoverError)
            throw voiceoverError
        }

        self.canonicalParentURL = canonicalParent
        self.currentFolderURL = canonicalFolder
        self.currentFolderIdentity = folderIdentity

        // 7. Output file creation inside verified dedicated folder
        let fileName = "voiceover-\(UUID().uuidString).m4a"
        let outputFile = canonicalFolder.appendingPathComponent(fileName, isDirectory: false)

        guard !FileManager.default.fileExists(atPath: outputFile.path) else {
            #if os(iOS) || targetEnvironment(macCatalyst)
            restoreAndDeactivateAudioSession()
            #endif
            let voiceoverError = TrailerVoiceoverError.fileCreationFailed("Output file already exists.")
            state = .error(voiceoverError)
            throw voiceoverError
        }

        // Configure native AAC settings
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000
        ]

        let newRecorder: AVAudioRecorder
        do {
            newRecorder = try AVAudioRecorder(url: outputFile, settings: settings)
        } catch {
            lastRecoveryURL = outputFile
            #if os(iOS) || targetEnvironment(macCatalyst)
            restoreAndDeactivateAudioSession()
            #endif
            let voiceoverError = TrailerVoiceoverError.startFailed(reason: "AVAudioRecorder initialization failed: \(error.localizedDescription)", recoveryURL: outputFile)
            state = .error(voiceoverError)
            throw voiceoverError
        }

        // Retain recorder immediately so any prepare/record failure stops it properly
        self.recorder = newRecorder
        let bridge = RecorderDelegateBridge(owner: self, generation: generation, recorder: newRecorder)
        self.recorderDelegateBridge = bridge
        newRecorder.delegate = bridge

        // 8. Prepare to record, verify regular audio file creation, and enforce mandatory 0600 permissions
        guard newRecorder.prepareToRecord() else {
            lastRecoveryURL = outputFile
            cleanupRecorderResources()
            #if os(iOS) || targetEnvironment(macCatalyst)
            restoreAndDeactivateAudioSession()
            #endif
            let voiceoverError = TrailerVoiceoverError.preparationFailed(recoveryURL: outputFile)
            state = .error(voiceoverError)
            throw voiceoverError
        }

        var isFileDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputFile.path, isDirectory: &isFileDir),
              !isFileDir.boolValue,
              !isSymbolicLink(at: outputFile) else {
            lastRecoveryURL = outputFile
            cleanupRecorderResources()
            #if os(iOS) || targetEnvironment(macCatalyst)
            restoreAndDeactivateAudioSession()
            #endif
            let voiceoverError = TrailerVoiceoverError.fileCreationFailed("Output audio file was not created as a regular file.")
            state = .error(voiceoverError)
            throw voiceoverError
        }

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: outputFile.path
            )
        } catch {
            lastRecoveryURL = outputFile
            cleanupRecorderResources()
            #if os(iOS) || targetEnvironment(macCatalyst)
            restoreAndDeactivateAudioSession()
            #endif
            let voiceoverError = TrailerVoiceoverError.fileCreationFailed("Failed to enforce mandatory 0600 permissions: \(error.localizedDescription)")
            state = .error(voiceoverError)
            throw voiceoverError
        }

        guard let fileIdentity = queryResourceIdentity(for: outputFile) else {
            lastRecoveryURL = outputFile
            cleanupRecorderResources()
            #if os(iOS) || targetEnvironment(macCatalyst)
            restoreAndDeactivateAudioSession()
            #endif
            let voiceoverError = TrailerVoiceoverError.fileCreationFailed("Failed to query output file resource identity.")
            state = .error(voiceoverError)
            throw voiceoverError
        }

        self.currentFileURL = outputFile
        self.currentFileIdentity = fileIdentity

        // 9. Begin recording
        guard newRecorder.record() else {
            lastRecoveryURL = outputFile
            cleanupRecorderResources()
            #if os(iOS) || targetEnvironment(macCatalyst)
            restoreAndDeactivateAudioSession()
            #endif
            let voiceoverError = TrailerVoiceoverError.startFailed(reason: "AVAudioRecorder.record() returned false", recoveryURL: outputFile)
            state = .error(voiceoverError)
            throw voiceoverError
        }

        #if os(iOS) || targetEnvironment(macCatalyst)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // 관찰자는 메인 큐에서 불리므로 알림을 다른 작업으로 넘기지 않고 같은 메인 격리에서 처리한다.
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated { self?.handleAudioInterruption(typeValue: typeValue) }
        }
        #endif

        state = .recording(requestID: requestID, fileURL: outputFile)
    }

    /// Stops current recording, waits for AVAudioRecorder finalization delegate, computes actual
    /// duration from audio file metadata, and preserves the ready artifact.
    func stopRecording() async throws -> TrailerVoiceoverArtifact {
        switch state {
        case .stopping:
            throw TrailerVoiceoverError.busy("녹음 중지 작업이 이미 진행 중입니다.")
        case .requesting, .idle, .ready, .error:
            throw TrailerVoiceoverError.notRecording
        case .recording(let requestID, let fileURL):
            guard let rec = recorder else {
                throw TrailerVoiceoverError.notRecording
            }
            state = .stopping(requestID: requestID, fileURL: fileURL)
            return try await withCheckedThrowingContinuation { continuation in
                self.stopContinuation = continuation
                rec.stop()
            }
        }
    }

    // MARK: - Hardware & Lifecycle Finalization

    private func requestMicrophonePermission(generation: Int) async -> Bool {
        let currentStatus = AVAudioApplication.shared.recordPermission
        if currentStatus == .granted {
            return true
        } else if currentStatus == .denied {
            return false
        }

        guard !Task.isCancelled else { return false }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled, self.activeGeneration == generation else {
                    continuation.resume(returning: false)
                    return
                }
                self.permissionContinuation = continuation
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        guard self.activeGeneration == generation else {
                            // Late callback from invalidated prompt is ignored
                            return
                        }
                        if let pending = self.permissionContinuation {
                            self.permissionContinuation = nil
                            pending.resume(returning: granted)
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.activeGeneration == generation else { return }
                if let pending = self.permissionContinuation {
                    self.permissionContinuation = nil
                    pending.resume(returning: false)
                }
            }
        }
    }

    #if os(iOS) || targetEnvironment(macCatalyst)
    private func configureAndActivateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        let saved = SavedAudioSessionState(
            category: session.category,
            mode: session.mode,
            options: session.categoryOptions
        )
        savedAudioSession = saved
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            restoreAndDeactivateAudioSession()
            throw error
        }
    }

    @discardableResult
    private func restoreAndDeactivateAudioSession() -> Bool {
        guard let saved = savedAudioSession else { return true }
        savedAudioSession = nil
        let session = AVAudioSession.sharedInstance()
        var success = true
        // Separate category restoration from deactivation so category failure never blocks deactivation
        do {
            try session.setCategory(saved.category, mode: saved.mode, options: saved.options)
        } catch {
            success = false
        }
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            success = false
        }
        return success
    }

    private func handleAudioInterruption(typeValue: UInt?) {
        guard case .recording = state else { return }
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .began else {
            return
        }

        // Invalidate delegate generation immediately so late callbacks cannot overwrite error
        activeGeneration += 1
        let fileURL = currentFileURL
        lastRecoveryURL = fileURL

        cleanupRecorderResources()
        restoreAndDeactivateAudioSession()

        let error = TrailerVoiceoverError.recordingFailed(reason: "시스템 오디오 인터럽트로 인해 녹음이 중단되었습니다.", recoveryURL: fileURL)
        state = .error(error)

        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume(throwing: error)
    }
    #endif

    private func cleanupRecorderResources() {
        recorder?.stop()
        recorder = nil
        recorderDelegateBridge = nil
        #if os(iOS) || targetEnvironment(macCatalyst)
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        #endif
    }

    // MARK: - Internal Delegate Event Handlers

    fileprivate func handleRecorderFinished(generation: Int, successfully: Bool) {
        guard generation == activeGeneration else { return }

        cleanupRecorderResources()

        #if os(iOS) || targetEnvironment(macCatalyst)
        restoreAndDeactivateAudioSession()
        #endif

        guard let fileURL = currentFileURL, let requestID = activeRequestID else {
            let error = TrailerVoiceoverError.audioFinalizationFailed(reason: "Missing active file or request metadata", recoveryURL: currentFileURL)
            state = .error(error)
            let continuation = stopContinuation
            stopContinuation = nil
            continuation?.resume(throwing: error)
            return
        }

        guard successfully else {
            lastRecoveryURL = fileURL
            let error = TrailerVoiceoverError.recordingFailed(reason: "AVAudioRecorder finished with failure flag", recoveryURL: fileURL)
            state = .error(error)
            let continuation = stopContinuation
            stopContinuation = nil
            continuation?.resume(throwing: error)
            return
        }

        // Calculate real finalized duration using AVAudioFile
        var finalizedDuration: Double = 0.0
        if let audioFile = try? AVAudioFile(forReading: fileURL) {
            let sampleRate = audioFile.fileFormat.sampleRate
            if sampleRate > 0 {
                finalizedDuration = Double(audioFile.length) / sampleRate
            }
        }

        guard finalizedDuration > 0.0 else {
            lastRecoveryURL = fileURL
            let error = TrailerVoiceoverError.audioFinalizationFailed(reason: "Finalized audio duration is non-positive or unreadable", recoveryURL: fileURL)
            state = .error(error)
            let continuation = stopContinuation
            stopContinuation = nil
            continuation?.resume(throwing: error)
            return
        }

        let artifact = TrailerVoiceoverArtifact(id: requestID, url: fileURL, duration: finalizedDuration)
        recordedArtifact = artifact
        state = .ready(artifact)

        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume(returning: artifact)
    }

    fileprivate func handleRecorderEncodeError(generation: Int, errorDescription: String?) {
        guard generation == activeGeneration else { return }
        // Invalidate delegate generation immediately so late finish callback cannot overwrite error
        activeGeneration += 1

        cleanupRecorderResources()

        #if os(iOS) || targetEnvironment(macCatalyst)
        restoreAndDeactivateAudioSession()
        #endif

        lastRecoveryURL = currentFileURL
        let reason = errorDescription ?? "Unknown audio encoding error"
        let error = TrailerVoiceoverError.recordingFailed(reason: reason, recoveryURL: currentFileURL)
        state = .error(error)

        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume(throwing: error)
    }

    // MARK: - Ownership & Preservation API

    /// Explicitly transfers ownership to caller and stops controller file tracking.
    /// Future cancellations will not delete this file.
    @discardableResult
    func markCommitted() -> TrailerVoiceoverArtifact? {
        guard let artifact = recordedArtifact else { return nil }
        isCommitted = true
        return artifact
    }

    /// Releases the recorded artifact from controller management without deleting files.
    /// Cannot be called during requesting, recording, or stopping states.
    @discardableResult
    func releaseArtifact() -> TrailerVoiceoverArtifact? {
        guard case .ready = state else {
            return nil
        }
        let artifact = recordedArtifact
        isCommitted = true
        recordedArtifact = nil
        currentFileURL = nil
        currentFolderURL = nil
        currentFileIdentity = nil
        currentFolderIdentity = nil
        lastRecoveryURL = nil
        state = .idle
        return artifact
    }

    /// Releases and returns the recovery URL for partial or failed recording output without deleting files.
    /// Cannot be called while recording or stopping is active.
    @discardableResult
    func releaseRecoveryURL() -> URL? {
        switch state {
        case .requesting, .recording, .stopping:
            return nil
        case .idle, .ready, .error:
            guard let recoveryURL = lastRecoveryURL ?? currentFileURL else { return nil }
            let released = recoveryURL
            isCommitted = true
            lastRecoveryURL = nil
            currentFileURL = nil
            currentFolderURL = nil
            currentFileIdentity = nil
            currentFolderIdentity = nil
            if case .error = state {
                state = .idle
            }
            return released
        }
    }

    /// Stops recording if active and preserves recorded data on disk.
    /// Intended for view dismissal or application shutdown; never deletes recorded output.
    func handleViewCloseOrShutdown() async {
        switch state {
        case .requesting:
            activeGeneration += 1
            if let continuation = permissionContinuation {
                permissionContinuation = nil
                continuation.resume(returning: false)
            }
            state = .idle
        case .recording:
            _ = try? await stopRecording()
        case .stopping:
            return
        case .idle, .ready, .error:
            break
        }
        cleanupRecorderResources()
        #if os(iOS) || targetEnvironment(macCatalyst)
        restoreAndDeactivateAudioSession()
        #endif
    }

    /// Explicit user cancellation: stops active recording, releases microphone/session,
    /// and deletes ONLY this controller's verified own uncommitted file and empty dedicated folder.
    /// Committed outputs and caller source files are never deleted.
    func cancel() async {
        activeGeneration += 1

        if let continuation = permissionContinuation {
            permissionContinuation = nil
            continuation.resume(returning: false)
        }

        if let continuation = stopContinuation {
            stopContinuation = nil
            continuation.resume(throwing: TrailerVoiceoverError.cancelled)
        }

        cleanupRecorderResources()

        #if os(iOS) || targetEnvironment(macCatalyst)
        restoreAndDeactivateAudioSession()
        #endif

        guard !isCommitted else {
            currentFileURL = nil
            currentFolderURL = nil
            currentFileIdentity = nil
            currentFolderIdentity = nil
            recordedArtifact = nil
            state = .idle
            return
        }

        var deletionError: (any Error)?

        // 1. Delete owned audio file if canonical hierarchy and resource identity still match
        if let fileURL = currentFileURL {
            if let expectedFileIdentity = currentFileIdentity,
               let folderURL = currentFolderURL,
               let expectedFolderIdentity = currentFolderIdentity,
               let parentURL = canonicalParentURL,
               let requestID = activeRequestID {
                let canonicalFile = fileURL.standardizedFileURL.resolvingSymlinksInPath()
                let canonicalFolder = folderURL.standardizedFileURL.resolvingSymlinksInPath()
                let canonicalParent = parentURL.standardizedFileURL.resolvingSymlinksInPath()

                let parentIsCanonicalCurrent = (canonicalParent.path == parentURL.path)
                    && (canonicalParent.path != "/")
                    && !isSymbolicLink(at: parentURL)
                let expectedFolderName = "Voiceover-\(requestID.uuidString)"
                let folderIsDirectChild = (canonicalFolder.deletingLastPathComponent().path == canonicalParent.path)
                let folderMatchesName = (canonicalFolder.lastPathComponent == expectedFolderName)
                let folderNotParent = (canonicalFolder.path != canonicalParent.path)
                let folderMinDepth = (canonicalFolder.pathComponents.count >= 3 && canonicalFolder.path != "/")
                let folderNotSymlink = !isSymbolicLink(at: folderURL)
                let folderIdentityMatches = (queryResourceIdentity(for: folderURL) == expectedFolderIdentity)

                var isFileDir: ObjCBool = false
                let fileExistsAsNonDir = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isFileDir) && !isFileDir.boolValue
                var fileStat = stat()
                let fileIsPosixRegular = (lstat(fileURL.path, &fileStat) == 0) && ((fileStat.st_mode & S_IFMT) == S_IFREG)
                let fileMatchesFolder = (canonicalFile.deletingLastPathComponent().path == canonicalFolder.path)
                let fileNotFolder = (canonicalFile.path != canonicalFolder.path && canonicalFile.path != canonicalParent.path)
                let fileMinDepth = (canonicalFile.pathComponents.count >= 4 && canonicalFile.path != "/")
                let fileNotSymlink = !isSymbolicLink(at: fileURL)
                let fileIdentityMatches = (queryResourceIdentity(for: fileURL) == expectedFileIdentity)

                let folderValid = parentIsCanonicalCurrent
                    && folderIsDirectChild
                    && folderMatchesName
                    && folderNotParent
                    && folderMinDepth
                    && folderNotSymlink
                    && folderIdentityMatches

                let fileValid = fileExistsAsNonDir
                    && fileIsPosixRegular
                    && fileMatchesFolder
                    && fileNotFolder
                    && fileMinDepth
                    && fileNotSymlink
                    && fileIdentityMatches

                if folderValid && fileValid {
                    if Darwin.unlink(canonicalFile.path) != 0 {
                        let err = errno
                        let reason = String(cString: strerror(err))
                        deletionError = TrailerVoiceoverError.recordingFailed(
                            reason: "POSIX unlink failed (errno \(err)): \(reason)",
                            recoveryURL: fileURL
                        )
                    } else {
                        currentFileURL = nil
                        currentFileIdentity = nil
                    }
                } else {
                    deletionError = TrailerVoiceoverError.recordingFailed(
                        reason: "File identity/hierarchy mismatch or target was replaced; deletion aborted for preservation.",
                        recoveryURL: fileURL
                    )
                }
            } else if currentFileIdentity == nil {
                deletionError = TrailerVoiceoverError.recordingFailed(
                    reason: "Missing file resource identity; deletion unauthorized.",
                    recoveryURL: fileURL
                )
            } else {
                deletionError = TrailerVoiceoverError.recordingFailed(
                    reason: "Missing folder, parent, or request metadata; file deletion aborted for preservation.",
                    recoveryURL: fileURL
                )
            }
        }

        // 2. Delete dedicated folder ONLY if confirmed empty owned child
        if deletionError == nil, let folderURL = currentFolderURL {
            if let expectedFolderIdentity = currentFolderIdentity,
               let parentURL = canonicalParentURL,
               let requestID = activeRequestID {
                let canonicalFolder = folderURL.standardizedFileURL.resolvingSymlinksInPath()
                let canonicalParent = parentURL.standardizedFileURL.resolvingSymlinksInPath()

                let expectedFolderName = "Voiceover-\(requestID.uuidString)"
                let parentIsCanonical = (canonicalParent.path == parentURL.path)
                    && (canonicalParent.path != "/")
                    && !isSymbolicLink(at: parentURL)
                let matchesParent = (canonicalFolder.deletingLastPathComponent().path == canonicalParent.path)
                let matchesName = (canonicalFolder.lastPathComponent == expectedFolderName)
                let notParent = (canonicalFolder.path != canonicalParent.path)
                let minDepth = (canonicalFolder.pathComponents.count >= 3 && canonicalFolder.path != "/")
                let notSymlink = !isSymbolicLink(at: folderURL)
                let identityMatches = (queryResourceIdentity(for: folderURL) == expectedFolderIdentity)

                if parentIsCanonical && matchesParent && matchesName && notParent && minDepth && notSymlink && identityMatches {
                    do {
                        let remaining = try FileManager.default.contentsOfDirectory(atPath: canonicalFolder.path)
                        if remaining.isEmpty {
                            if Darwin.rmdir(canonicalFolder.path) != 0 {
                                let err = errno
                                let reason = String(cString: strerror(err))
                                deletionError = TrailerVoiceoverError.recordingFailed(
                                    reason: "POSIX rmdir failed (errno \(err)): \(reason)",
                                    recoveryURL: currentFileURL ?? folderURL
                                )
                            } else {
                                currentFolderURL = nil
                                currentFolderIdentity = nil
                            }
                        } else {
                            deletionError = TrailerVoiceoverError.recordingFailed(
                                reason: "Dedicated folder is not empty; recursive removal prevented.",
                                recoveryURL: currentFileURL ?? folderURL
                            )
                        }
                    } catch {
                        deletionError = error
                    }
                } else {
                    deletionError = TrailerVoiceoverError.recordingFailed(
                        reason: "Folder identity mismatch or target was replaced; deletion aborted for preservation.",
                        recoveryURL: currentFileURL ?? folderURL
                    )
                }
            } else {
                deletionError = TrailerVoiceoverError.recordingFailed(
                    reason: "Missing folder identity or parent metadata; folder deletion unauthorized.",
                    recoveryURL: currentFileURL ?? folderURL
                )
            }
        }

        if let error = deletionError {
            lastRecoveryURL = currentFileURL ?? currentFolderURL
            let surfacedError: TrailerVoiceoverError
            if let voError = error as? TrailerVoiceoverError {
                surfacedError = voError
            } else {
                surfacedError = TrailerVoiceoverError.recordingFailed(
                    reason: "취소 파일 정리 실패: \(error.localizedDescription)",
                    recoveryURL: lastRecoveryURL
                )
            }
            state = .error(surfacedError)
        } else {
            currentFileURL = nil
            currentFolderURL = nil
            currentFileIdentity = nil
            currentFolderIdentity = nil
            recordedArtifact = nil
            state = .idle
        }
    }
}

// MARK: - Nonisolated Recorder Delegate Bridge

private final class RecorderDelegateBridge: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    private weak var owner: TrailerVoiceoverRecorder?
    private let generation: Int
    private let recorderID: ObjectIdentifier

    init(owner: TrailerVoiceoverRecorder, generation: Int, recorder: AVAudioRecorder) {
        self.owner = owner
        self.generation = generation
        self.recorderID = ObjectIdentifier(recorder)
        super.init()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard ObjectIdentifier(recorder) == self.recorderID else { return }
        let gen = self.generation
        Task { @MainActor [weak owner] in
            owner?.handleRecorderFinished(generation: gen, successfully: flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        guard ObjectIdentifier(recorder) == self.recorderID else { return }
        let gen = self.generation
        let desc = error?.localizedDescription
        Task { @MainActor [weak owner] in
            owner?.handleRecorderEncodeError(generation: gen, errorDescription: desc)
        }
    }
}

// MARK: - On-Device Caption Transcriber Errors

/// Typed errors produced during on-device caption transcription.
enum TrailerTranscriptionError: LocalizedError, Equatable, Sendable {
    case missingPrivacyDescription
    case permissionDenied
    case unsupportedLocale
    case notAvailable
    case onDeviceUnavailable
    case invalidSource(String)
    case cancelled
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPrivacyDescription:
            return "NSSpeechRecognitionUsageDescription이 Info.plist에 정의되지 않았습니다."
        case .permissionDenied:
            return "음성 인식 권한이 거부되었습니다."
        case .unsupportedLocale:
            return "지정된 로케일은 음성 인식을 지원하지 않습니다."
        case .notAvailable:
            return "음성 인식 서비스를 현재 사용할 수 없습니다."
        case .onDeviceUnavailable:
            return "온디바이스 음성 인식을 지원하지 않는 환경입니다."
        case .invalidSource(let reason):
            return "유효하지 않은 오디오 소스입니다: \(reason)"
        case .cancelled:
            return "음성 인식 작업이 취소되었습니다."
        case .recognitionFailed(let reason):
            return "음성 인식에 실패했습니다: \(reason)"
        }
    }
}

// MARK: - On-Device Caption Transcriber

/// MainActor controller performing speech recognition on prepared local audio files using on-device models.
///
/// Availability: macOS 10.15+, iOS 13.0+, macCatalyst 13.1+.
/// Operates strictly on-device with zero network fallback, never mutates caller files.
@available(macOS 10.15, iOS 13.0, macCatalyst 13.1, *)
@MainActor
final class TrailerOnDeviceCaptionTranscriber {
    private var activeGeneration: Int = 0
    private var activeRequestID: UUID?
    nonisolated(unsafe) private var activeTask: SFSpeechRecognitionTask?
    private var activeRecognizer: SFSpeechRecognizer?
    private var pendingContinuation: CheckedContinuation<[TrailerTimedCaptionCue], any Error>?
    private var authContinuation: CheckedContinuation<Bool, Never>?

    init() {
        // Init does not trigger speech engine or request permissions.
    }

    deinit {
        activeTask?.cancel()
    }

    /// Explicitly cancels any current transcription generation in flight.
    func cancel() {
        activeGeneration += 1
        activeRequestID = nil
        cancelPendingOperations()
    }

    /// Generates timed caption cues from a prepared local audio file.
    ///
    /// - Parameters:
    ///   - audioURL: Local file URL of the audio file to transcribe.
    ///   - sourceID: Identifier of the clip or track in the trailer project.
    ///   - sourceOffset: Non-negative offset in seconds to add to detected timestamps.
    ///   - localeIdentifier: BCP-47 language tag (defaults to current system locale).
    ///   - style: Base visual style to apply to generated caption cues.
    /// - Returns: List of generated `TrailerTimedCaptionCue` instances with positive durations.
    func generateCaptions(
        for audioURL: URL,
        sourceID: Int,
        sourceOffset: Double = 0.0,
        localeIdentifier: String = Locale.current.identifier,
        style: TrailerCaption = TrailerCaption()
    ) async throws -> [TrailerTimedCaptionCue] {
        // 1. Cancel any previous overlapping operation first so invalid input never leaves a task running secretly
        cancelPendingOperations()

        // 2. Validate audio file source
        guard audioURL.isFileURL else {
            throw TrailerTranscriptionError.invalidSource("Audio URL must be a file URL.")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: audioURL.path, isDirectory: &isDir), !isDir.boolValue else {
            throw TrailerTranscriptionError.invalidSource("Audio file does not exist or is a directory.")
        }
        guard FileManager.default.isReadableFile(atPath: audioURL.path) else {
            throw TrailerTranscriptionError.invalidSource("Audio file is not readable.")
        }
        guard sourceOffset.isFinite, sourceOffset >= 0.0 else {
            throw TrailerTranscriptionError.invalidSource("sourceOffset must be a finite, non-negative number.")
        }

        // 3. Pre-flight privacy description check BEFORE speech framework authorization
        guard let usageDesc = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String,
              !usageDesc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrailerTranscriptionError.missingPrivacyDescription
        }

        // 4. Update request generation tracking
        activeGeneration += 1
        let generation = activeGeneration
        let requestID = UUID()
        activeRequestID = requestID

        // 5. Wrap the entire per-request operation (including permission wait) in a generation-bound cancellation handler
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled, self.activeGeneration == generation, self.activeRequestID == requestID else {
                throw TrailerTranscriptionError.cancelled
            }

            // Request speech authorization if not determined
            let authorized = await requestSpeechAuthorization(generation: generation, requestID: requestID)
            guard self.activeGeneration == generation, self.activeRequestID == requestID, !Task.isCancelled else {
                throw TrailerTranscriptionError.cancelled
            }
            guard authorized else {
                throw TrailerTranscriptionError.permissionDenied
            }

            // Initialize SFSpeechRecognizer with locale and verify on-device support
            let locale = Locale(identifier: localeIdentifier)
            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                throw TrailerTranscriptionError.unsupportedLocale
            }
            guard recognizer.isAvailable else {
                throw TrailerTranscriptionError.notAvailable
            }
            guard recognizer.supportsOnDeviceRecognition else {
                throw TrailerTranscriptionError.onDeviceUnavailable
            }
            self.activeRecognizer = recognizer

            // Prepare strictly on-device recognition request (NO cloud fallback)
            let request = SFSpeechURLRecognitionRequest(url: audioURL)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false

            guard !Task.isCancelled, self.activeGeneration == generation, self.activeRequestID == requestID else {
                cleanupTask()
                throw TrailerTranscriptionError.cancelled
            }

            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, self.activeGeneration == generation, self.activeRequestID == requestID else {
                    continuation.resume(throwing: TrailerTranscriptionError.cancelled)
                    return
                }
                self.pendingContinuation = continuation

                let task = recognizer.recognitionTask(with: request) { [weak self] (result, error) in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.handleRecognitionCallback(
                            generation: generation,
                            requestID: requestID,
                            sourceID: sourceID,
                            sourceOffset: sourceOffset,
                            style: style,
                            result: result,
                            error: error
                        )
                    }
                }
                self.activeTask = task
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelIfMatching(generation: generation, requestID: requestID)
            }
        }
    }

    // MARK: - Internal Recognition Handling

    private func handleRecognitionCallback(
        generation: Int,
        requestID: UUID,
        sourceID: Int,
        sourceOffset: Double,
        style: TrailerCaption,
        result: SFSpeechRecognitionResult?,
        error: (any Error)?
    ) {
        guard generation == activeGeneration, requestID == activeRequestID else {
            // Reject stale callback from older generation
            return
        }
        guard pendingContinuation != nil else {
            // Continuation already completed; duplicate final callbacks cannot change state
            return
        }

        // Deterministic result vs error evaluation policy:
        // 1. If final result with transcribed segments exists, prioritize delivering it.
        // 2. Otherwise if error occurred, surface typed error.
        // 3. Otherwise if final result exists with no segments (silence), deliver empty array.
        if let result = result, result.isFinal, !result.bestTranscription.segments.isEmpty {
            let segments = result.bestTranscription.segments
            var cues: [TrailerTimedCaptionCue] = []

            for segment in segments {
                let trimmed = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                let segTimestamp = segment.timestamp
                let segDuration = segment.duration
                guard segTimestamp.isFinite, segTimestamp >= 0.0 else { continue }
                guard segDuration.isFinite, segDuration > 0.0 else { continue }

                let cueStart = sourceOffset + segTimestamp
                guard cueStart.isFinite, cueStart >= 0.0 else { continue }

                let cueEnd = cueStart + segDuration
                guard cueEnd.isFinite, cueEnd > cueStart else { continue }

                let cue = TrailerTimedCaptionCue(
                    stableID: UUID(),
                    sourceID: sourceID,
                    sourceStart: cueStart,
                    sourceEnd: cueEnd,
                    text: trimmed,
                    style: style,
                    origin: .generated,
                    manuallyEdited: false
                )
                cues.append(cue)
            }

            cleanupTask()
            let continuation = pendingContinuation
            pendingContinuation = nil
            continuation?.resume(returning: cues)
            return
        }

        if let error = error {
            cleanupTask()
            let transcriptionError: TrailerTranscriptionError
            let nsError = error as NSError
            if nsError.domain == "kLSRErrorDomain" && nsError.code == 301 {
                transcriptionError = .cancelled
            } else {
                transcriptionError = .recognitionFailed(error.localizedDescription)
            }
            let continuation = pendingContinuation
            pendingContinuation = nil
            continuation?.resume(throwing: transcriptionError)
            return
        }

        if let result = result, result.isFinal {
            cleanupTask()
            let continuation = pendingContinuation
            pendingContinuation = nil
            continuation?.resume(returning: [])
            return
        }

        // Partial results without error are ignored because shouldReportPartialResults is false
    }

    private func requestSpeechAuthorization(generation: Int, requestID: UUID) async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            guard !Task.isCancelled, self.activeGeneration == generation, self.activeRequestID == requestID else {
                return false
            }
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled, self.activeGeneration == generation, self.activeRequestID == requestID else {
                    continuation.resume(returning: false)
                    return
                }
                self.authContinuation = continuation
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        guard self.activeGeneration == generation, self.activeRequestID == requestID else {
                            return
                        }
                        if let pending = self.authContinuation {
                            self.authContinuation = nil
                            pending.resume(returning: newStatus == .authorized)
                        }
                    }
                }
            }
        @unknown default:
            return false
        }
    }

    private func cancelIfMatching(generation: Int, requestID: UUID) {
        guard activeGeneration == generation, activeRequestID == requestID else {
            return
        }
        activeGeneration += 1
        activeRequestID = nil
        cancelPendingOperations()
    }

    private func cancelPendingOperations() {
        if let continuation = authContinuation {
            authContinuation = nil
            continuation.resume(returning: false)
        }

        if let continuation = pendingContinuation {
            pendingContinuation = nil
            continuation.resume(throwing: TrailerTranscriptionError.cancelled)
        }

        cleanupTask()
    }

    private func cleanupTask() {
        activeTask?.cancel()
        activeTask = nil
        activeRecognizer = nil
    }
}
