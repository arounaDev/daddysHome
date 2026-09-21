import AVFoundation
import FluidAudio

enum VoiceCaptureState {
    case idle
    case recording
    case transcribing
}

/// Raw mono samples handed over from CoreAudio's real-time tap thread.
///
/// The tap block runs on a thread with a hard deadline, so it does the
/// cheapest thing possible — downmix and copy — and everything else waits
/// for `drain()` on the main actor. A plain captured `var` would be a data
/// race between that thread and the stop path.
private final class SampleAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ incoming: [Float]) {
        lock.withLock { samples.append(contentsOf: incoming) }
    }

    func drain() -> [Float] {
        lock.withLock {
            defer { samples = [] }
            return samples
        }
    }
}

/// Daddy's own mic capture: double-tap Option starts recording, a second tap
/// stops and hands off the final transcript, Esc cancels.
///
/// Transcription is Parakeet TDT v3 running on the Neural Engine through
/// FluidAudio — fully on-device, and multilingual, so English and Spanish
/// are both recognised without anyone choosing a locale first. It replaced
/// `SFSpeechRecognizer`, which was pinned to `en-US` and mangled every
/// Spanish utterance.
@MainActor
@Observable
final class VoiceCaptureController {
    private(set) var state: VoiceCaptureState = .idle

    /// Set when the models cannot be loaded. Surfaced rather than swallowed:
    /// without it a failed load is indistinguishable from a dead hotkey.
    private(set) var engineError: String?

    private let hotkeyMonitor = OptionDoubleTapMonitor()
    private let audioEngine = AVAudioEngine()
    private let accumulator = SampleAccumulator()

    /// The mic's own rate, captured when the tap is installed. The samples
    /// are resampled to the 16 kHz Parakeet expects only once, at the end.
    private var captureSampleRate: Double = 48_000
    private var transcriptionGeneration = 0

    /// One shared load for the whole process. Started from `start()` so the
    /// first recording does not pay for it — on a machine that has never run
    /// these models, CoreML compiles them for the local ANE on first load,
    /// which takes about a minute. Every load after that is a fifth of a
    /// second.
    private var modelLoad: Task<AsrManager, Error>?

    /// Fired with the final transcript once a recording completes normally
    /// (not cancelled). The caller resolves and executes it.
    var onTranscript: ((String) -> Void)?

    func start() {
        hotkeyMonitor.onDoubleTap = { [weak self] in self?.beginRecording() }
        hotkeyMonitor.onSingleTapWhileActive = { [weak self] in self?.handleTapWhileActive() }
        hotkeyMonitor.onEscape = { [weak self] in self?.cancelRecording() }
        hotkeyMonitor.start()
        _ = modelsTask()
    }

    func stop() {
        hotkeyMonitor.stop()
        cancelRecording()
    }

    // MARK: - Models

    private func modelsTask() -> Task<AsrManager, Error> {
        if let modelLoad { return modelLoad }
        let task = Task<AsrManager, Error> {
            let models = try await Self.loadModels()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        modelLoad = task
        return task
    }

    /// Prefers the already-staged bundle in FluidAudio's own cache directory
    /// and only reaches for the network if it is missing or unreadable. Hex
    /// stages the identical files there, so on this machine the download
    /// never runs.
    ///
    /// `loadLocal` rather than `load`, which is not the offline call it looks
    /// like: `load(from:)` keeps only the *parent* of the directory you hand
    /// it, re-derives the leaf from the model version, and routes the result
    /// through `ModelHub` — so it will happily download a second copy while
    /// reporting that it is loading from your path. `loadLocal` opens exactly
    /// the files in exactly this directory and never touches the network.
    private nonisolated static func loadModels() async throws -> AsrModels {
        let cached = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3",
                isDirectory: true
            )
        if FileManager.default.fileExists(atPath: cached.path) {
            if let models = try? await AsrModels.loadLocal(from: cached, version: .v3) {
                return models
            }
        }
        return try await AsrModels.downloadAndLoad(version: .v3)
    }

    // MARK: - Recording

    private func beginRecording() {
        guard state == .idle else { return }
        Self.requestMicPermissionIfNeeded { [weak self] granted in
            guard granted else { return }
            Task { @MainActor [weak self] in
                self?.startEngine()
            }
        }
    }

    private func startEngine() {
        guard state == .idle else { return }

        _ = accumulator.drain()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        captureSampleRate = format.sampleRate

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: Self.makeTapBlock(appendingTo: accumulator)
        )

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            return
        }

        state = .recording
        hotkeyMonitor.isActive = true
    }

    /// `nonisolated` for the same reason the permission request below is:
    /// this block runs on CoreAudio's real-time tap thread, never main.
    /// Written as a closure literal inside a `@MainActor` method, Swift
    /// infers it as MainActor-isolated even though it touches no isolated
    /// state — and the runtime isolation check traps the instant CoreAudio
    /// invokes it off-main. Building it in a `nonisolated` factory breaks
    /// that inference.
    ///
    /// Multi-channel input is averaged down to mono here rather than later,
    /// so only one channel's worth of samples is ever retained.
    private nonisolated static func makeTapBlock(
        appendingTo accumulator: SampleAccumulator
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }
            let channelCount = Int(buffer.format.channelCount)

            if channelCount == 1 {
                accumulator.append(Array(UnsafeBufferPointer(start: channels[0], count: frameCount)))
                return
            }

            var mono = [Float](repeating: 0, count: frameCount)
            for channel in 0..<channelCount {
                let source = channels[channel]
                for frame in 0..<frameCount {
                    mono[frame] += source[frame]
                }
            }
            let scale = 1 / Float(channelCount)
            for frame in 0..<frameCount {
                mono[frame] *= scale
            }
            accumulator.append(mono)
        }
    }

    private func handleTapWhileActive() {
        switch state {
        case .recording:
            finishRecording()
        case .transcribing:
            teardownToIdle()
        case .idle:
            break
        }
    }

    private func finishRecording() {
        guard state == .recording else { return }
        state = .transcribing
        // Stays active through transcribing so a tap or Esc always gets out,
        // even before the transcript lands.
        transcriptionGeneration += 1
        let generation = transcriptionGeneration

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        let samples = accumulator.drain()
        let inputRate = captureSampleRate

        guard !samples.isEmpty else {
            teardownToIdle()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let manager = try await self.modelsTask().value
                let text = try await Self.transcribe(samples, from: inputRate, using: manager)
                guard generation == self.transcriptionGeneration, self.state == .transcribing else { return }
                self.handleFinalTranscript(text)
            } catch {
                guard generation == self.transcriptionGeneration, self.state == .transcribing else { return }
                self.engineError = String(describing: error)
                self.teardownToIdle()
            }
        }

        // Backstop: the pill must never outlive the transcription. Generous
        // because the very first load on a new machine compiles the CoreML
        // models before anything can be transcribed.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(90))
            self?.handleTranscriptionTimeout(generation: generation)
        }
    }

    /// No `language:` argument, deliberately — left unset, Parakeet v3
    /// detects the language itself, which is the whole point of the swap.
    private nonisolated static func transcribe(
        _ samples: [Float],
        from inputRate: Double,
        using manager: AsrManager
    ) async throws -> String {
        let converter = AudioConverter()
        let resampled = try converter.resample(samples, from: inputRate)
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(resampled, decoderState: &decoderState)
        return result.text
    }

    func cancelRecording() {
        guard state == .recording || state == .transcribing else { return }
        transcriptionGeneration += 1
        teardownToIdle()
    }

    /// Every exit path funnels here — engine, tap, buffered samples, state —
    /// so the pill can never stick.
    private func teardownToIdle() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        _ = accumulator.drain()
        hotkeyMonitor.isActive = false
        state = .idle
    }

    private func handleTranscriptionTimeout(generation: Int) {
        guard generation == transcriptionGeneration, state == .transcribing else { return }
        teardownToIdle()
    }

    private func handleFinalTranscript(_ text: String) {
        hotkeyMonitor.isActive = false
        state = .idle
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onTranscript?(trimmed)
    }

    /// `nonisolated`, with no `self` or MainActor capture. A closure written
    /// inside a `@MainActor` method that captures `self` gets inferred as
    /// MainActor-isolated, and Swift's runtime isolation check traps the
    /// instant TCC invokes it from its own internal thread.
    ///
    /// Only the microphone is requested now. The Speech authorization that
    /// used to be paired with it here belonged to `SFSpeechRecognizer`;
    /// Parakeet runs entirely in-process and never touches that service, so
    /// asking for it would be prompting for a permission nothing uses.
    private nonisolated static func requestMicPermissionIfNeeded(
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
