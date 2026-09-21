import AVFoundation
import FluidAudio

/// What made Daddy speak. Each one can be silenced on its own, because the
/// useful set is personal: the idle line earns its keep when you are in
/// another window, the confirmations mostly matter when you are watching.
enum SpeechEvent: String, CaseIterable {
    case agentIdle
    case actionConfirmed
    case actionFailed
}

/// How much Daddy talks.
enum SpeechMode: String, CaseIterable {
    /// Silent unless you ask for a specific line out loud.
    case off
    /// Speaks the events in `SpeechEvent`, nothing else.
    case events

    var label: String {
        switch self {
        case .off: return "Off"
        case .events: return "On events"
        }
    }
}

/// Daddy's voice: Kokoro, on-device, through FluidAudio — the same package
/// that already does the listening.
///
/// There is deliberately no second engine. `AVSpeechSynthesizer` was here as a
/// fallback and was taken out: one voice means one thing to tune and one
/// sound to get used to. The cost is that a Kokoro failure is silence rather
/// than a worse voice, which is why `engineError` exists — a feature that
/// quietly stops working is worse than one that says it broke.
@MainActor
@Observable
final class SpeechOutputController: NSObject {

    /// The British male voice from Kokoro's English pack. Changing this is
    /// safe: any id from `KokoroAneConstants.englishVoices` works, and the
    /// pack is fetched on first use.
    static let voice = "bm_lewis"

    /// True from the moment audio starts until it stops or is cut off. The
    /// mic reads this: Daddy must never transcribe itself.
    private(set) var isSpeaking = false

    /// Set when Kokoro could not be loaded or a line could not be spoken.
    /// Surfaced rather than swallowed, for the same reason as the mic's
    /// `engineError`.
    private(set) var engineError: String?

    var mode: SpeechMode {
        didSet { Defaults.set(mode.rawValue, for: .speechMode) }
    }

    private var enabledEvents: Set<SpeechEvent> {
        didSet { persistEvents() }
    }

    private var player: AVAudioPlayer?

    /// Incremented by every `stopSpeaking()` and every new line, so audio that
    /// finished synthesizing after it was cancelled never reaches the speaker.
    private var generation = 0

    /// One shared load, started on first use rather than at launch: unlike the
    /// mic — which must be ready the instant you double-tap — nothing speaks
    /// until something happens worth speaking about. The first line therefore
    /// pays for the download; every one after it is immediate.
    private var kokoroLoad: Task<KokoroAneManager, Error>?

    override init() {
        mode = Defaults.string(.speechMode).flatMap(SpeechMode.init) ?? .events
        if let stored = Defaults.string(.speechEvents) {
            enabledEvents = Set(stored.split(separator: ",").compactMap { SpeechEvent(rawValue: String($0)) })
        } else {
            enabledEvents = Set(SpeechEvent.allCases)
        }
        super.init()
    }

    // MARK: - Per-event switches

    func isEnabled(_ event: SpeechEvent) -> Bool {
        enabledEvents.contains(event)
    }

    func setEnabled(_ enabled: Bool, for event: SpeechEvent) {
        if enabled {
            enabledEvents.insert(event)
        } else {
            enabledEvents.remove(event)
        }
    }

    private func persistEvents() {
        Defaults.set(enabledEvents.map(\.rawValue).sorted().joined(separator: ","), for: .speechEvents)
    }

    // MARK: - Speaking

    /// An automatic line. Silent unless the mode allows it and this particular
    /// event is switched on.
    func announce(_ text: String, event: SpeechEvent) {
        guard mode == .events, isEnabled(event) else { return }
        speak(text)
    }

    /// A line you asked for. Ignores `mode` — pressing the button is the
    /// answer to "should this be spoken".
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // A new line replaces whatever is talking rather than queueing behind
        // it. These are status announcements: the most recent one is the only
        // one still true.
        stopSpeaking()

        generation += 1
        let generation = self.generation
        isSpeaking = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let manager = try await self.kokoroTask().value
                let wav = try await manager.synthesize(text: trimmed, voice: Self.voice)
                guard generation == self.generation else { return }
                let player = try AVAudioPlayer(data: wav)
                player.delegate = self
                self.player = player
                player.play()
            } catch {
                guard generation == self.generation else { return }
                self.engineError = String(describing: error)
                self.isSpeaking = false
            }
        }
    }

    /// Cuts off whatever is being said, immediately. Called when recording
    /// starts, so the mic never hears Daddy.
    func stopSpeaking() {
        generation += 1
        player?.stop()
        player = nil
        isSpeaking = false
    }

    private func kokoroTask() -> Task<KokoroAneManager, Error> {
        if let kokoroLoad { return kokoroLoad }
        let task = Task<KokoroAneManager, Error> {
            let manager = KokoroAneManager(variant: .english, defaultVoice: Self.voice)
            try await manager.initialize(preloadVoices: [Self.voice])
            return manager
        }
        kokoroLoad = task
        return task
    }
}

extension SpeechOutputController: AVAudioPlayerDelegate {
    /// The player is compared by `ObjectIdentifier` rather than carried into
    /// the task: `AVAudioPlayer` is not `Sendable`, so sending the object
    /// itself across the actor hop is a data race the compiler rejects. The
    /// identity is all this needs — it answers "is the thing that just
    /// finished still the thing that is playing", and a stale callback from a
    /// replaced player must not clear the new one's `isSpeaking`.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player,
                  ObjectIdentifier(current) == finished else { return }
            self.player = nil
            self.isSpeaking = false
        }
    }
}
