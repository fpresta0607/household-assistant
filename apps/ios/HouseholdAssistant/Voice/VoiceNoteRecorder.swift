// Records a voice note: AAC in an m4a, with the microphone's level read twenty times a
// second for the live waveform and for the bars the note carries. What to do when is the
// gesture's to decide (Model/VoiceNoteGesture.swift); this only does it.
//
// The note starts the moment the microphone is touched, so the first syllable is in it.
// While a conversation is on screen two things are kept warm: the audio session, active
// in the record-capable category and still mixing with whatever else plays, and the next
// note's recorder, made with its settings but not prepared, so no audio queue and no file
// exist yet. Neither reads the microphone, so the orange dot stays off; it lights only
// once `record()` starts the input. Touching the microphone then only has to start it:
// nothing to ask, and no session to switch, which is the slow part. A stopped note is
// kept to listen back to until it is sent or thrown away.
//
// Readying, starting and letting go switch the session or start the microphone's input,
// which blocks, so all of it happens on the sound's own queue (AudioFocus.soon), never on
// the touch: the recording shows the moment the finger lands, and the input starts right
// behind it. Stopping or sending a note waits for a start still under way, so nothing said
// is lost (CFO notes for ha-gia-appearance, section 6).

import AVFoundation
import Observation
import os

@MainActor
@Observable
final class VoiceNoteRecorder {
    /// The levels heard so far, 0...1, newest last.
    private(set) var levels: [Double]
    /// The note stopped and kept to listen back to.
    private(set) var kept: URL?

    /// A single warm-up shared with a press that arrives before it finishes.
    @ObservationIgnored private var warming: Task<Made, Never>?
    @ObservationIgnored private var wantsWarmth = false
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var metering: Task<Void, Never>?
    /// Whether a note is recording, for the sound's queue, which never gives the sound back
    /// from under one that a touch started before the queue came to it.
    @ObservationIgnored private let isRecordingNow = OSAllocatedUnfairLock(initialState: false)
    /// The start under way on the sound's queue, which stopping and sending wait for.
    /// Answers whether the input started.
    @ObservationIgnored private var starting: Task<Bool, Never>?
    /// Counts each start and each note thrown away, so a start that lands after its note was
    /// thrown away lets its recording go.
    @ObservationIgnored private var attempt = 0

    /// A recorder made on the sound's queue, handed to the main actor that keeps it.
    private final class Made: @unchecked Sendable {
        let recorder: AVAudioRecorder?

        init(_ recorder: AVAudioRecorder?) {
            self.recorder = recorder
        }
    }

    /// Ready to record and still mixing, so opening a conversation stops nobody's music,
    /// and Bluetooth headphones go on playing it.
    private static let readyOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
    /// Music playing on would be heard in the note, so it stops for the note as it does in
    /// Telegram, and carries on after.
    private static let recordingOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
    nonisolated(unsafe) private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    /// `levels` and `kept` let the screenshot tests show a note already recorded.
    init(levels: [Double] = [], kept: URL? = nil) {
        self.levels = levels
        self.kept = kept
    }

    /// Whether a note's start is still under way on the sound's queue. A note sent or
    /// stopped before its start lands still waits for it, so the next note waits too.
    var isStarting: Bool {
        starting != nil
    }

    /// Readies the next note without touching the microphone, on the sound's queue. Asks
    /// nothing; until the microphone is allowed it does nothing.
    func warm() {
        wantsWarmth = true
        guard recorder == nil, starting == nil, warming == nil,
              AVAudioApplication.shared.recordPermission == .granted else {
            return
        }
        let options = Self.readyOptions
        warming = Task {
            await withCheckedContinuation { continuation in
                AudioFocus.soon {
                    continuation.resume(returning: Made(Self.made(options: options)))
                }
            }
        }
    }

    /// Starts recording right behind the touch, which has already drawn the note: the
    /// readied recorder starts its input on the sound's queue, or, when other sound plays
    /// or something took the sound since, one made there afresh. Answers a plain sentence
    /// when the microphone would not start.
    func begin() async -> String? {
        VoiceNotePlayer.shared.stop()
        attempt += 1
        let mine = attempt
        // Consume the same warm-up even when it is still on the sound queue. Previously
        // a press threw it away and could try to record with no recorder at all.
        let prepared = warming
        warming = nil
        isRecordingNow.withLock { $0 = true }
        levels = []
        let options = (ready: Self.readyOptions, recording: Self.recordingOptions)
        let start = Task {
            let readied = await prepared?.value ?? Made(nil)
            let started = await Self.start(readied, readyOptions: options.ready, recordingOptions: options.recording)
            return self.adopt(started: started, attempt: mine)
        }
        starting = start
        return await start.value ? nil : "The microphone would not start."
    }

    /// The input started on the sound's queue, or not. Answers false only when this note's
    /// microphone would not start; a start for a note already thrown away lets it go.
    private func adopt(started: Made, attempt mine: Int) -> Bool {
        guard mine == attempt else {
            started.recorder?.stop()
            if let file = started.recorder?.url {
                try? FileManager.default.removeItem(at: file)
            }
            // The give-back queued when the note was thrown away found this recording
            // still running and could not let the sound go, so music it stopped stays
            // stopped until it is let go now.
            readyForTheNext()
            return true
        }
        starting = nil
        guard let next = started.recorder else {
            // Whatever went wrong, the next touch readies everything afresh.
            isRecordingNow.withLock { $0 = false }
            rest()
            return false
        }
        recorder = next
        ChatTiming.captureStarted()
        metering = Task { [weak self] in
            while !Task.isCancelled {
                self?.meter()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return true
    }

    /// On the sound's queue: the readied recorder while the sound is still held as it was
    /// readied and nothing else plays, or a new one, and its input started.
    nonisolated private static func start(
        _ readied: Made,
        readyOptions: AVAudioSession.CategoryOptions,
        recordingOptions: AVAudioSession.CategoryOptions
    ) async -> Made {
        await withCheckedContinuation { continuation in
            AudioFocus.soon {
                let isOtherAudioPlaying = AudioFocus.isOtherAudioPlaying
                var next = readied.recorder
                if next == nil || isOtherAudioPlaying || !AudioFocus.isHeld(.playAndRecord, mode: .default) {
                    if let unused = next {
                        try? FileManager.default.removeItem(at: unused.url)
                    }
                    next = Self.made(options: isOtherAudioPlaying ? recordingOptions : readyOptions)
                }
                let isRecording = next?.record() == true
                if !isRecording, let failed = next {
                    try? FileManager.default.removeItem(at: failed.url)
                }
                continuation.resume(returning: Made(isRecording ? next : nil))
            }
        }
    }

    /// Stops the note and keeps it to listen back to. Listening takes the sound for playing.
    func stop() async {
        _ = await starting?.value
        guard let recorder else {
            return
        }
        stopRecording()
        kept = recorder.url
        AudioFocus.giveBack()
    }

    /// Hands back the note, recording or kept, or nil when nothing was recorded, and
    /// readies the next.
    func finish(durationMs: Int) async -> RoomAttachment? {
        _ = await starting?.value
        let file = recorder?.url ?? kept
        stopRecording()
        defer {
            if let file {
                try? FileManager.default.removeItem(at: file)
            }
            kept = nil
            readyForTheNext()
        }
        guard let file, let data = try? Data(contentsOf: file), !data.isEmpty else {
            return nil
        }
        return RoomAttachment(
            data: data,
            kind: .voice,
            mime: "audio/mp4",
            durationMs: durationMs,
            waveform: Waveform.bars(from: levels)
        )
    }

    /// Throws the note away, recording, starting or kept, and readies the next.
    func cancel() {
        attempt += 1
        starting = nil
        throwAway()
        readyForTheNext()
    }

    /// Lets go of the sound kept ready, when the conversation closes or the app leaves the
    /// screen. A note kept to listen back to stays until it is sent or thrown away.
    func rest() {
        wantsWarmth = false
        discardReady()
        guard recorder == nil else {
            return
        }
        let isRecordingNow = isRecordingNow
        AudioFocus.soon {
            if !isRecordingNow.withLock({ $0 }), AudioFocus.isHeld(.playAndRecord, mode: .default) {
                AudioFocus.giveBack()
            }
        }
    }

    /// Takes the sound and makes a recorder. Deliberately not `prepareToRecord()`, which
    /// would build the input's audio queue while nobody is recording.
    nonisolated private static func made(options: AVAudioSession.CategoryOptions) -> AVAudioRecorder? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        guard
            (try? AudioFocus.take(.playAndRecord, mode: .default, options: options)) != nil,
            let next = try? AVAudioRecorder(url: file, settings: settings)
        else {
            return nil
        }
        next.isMeteringEnabled = true
        return next
    }

    private func meter() {
        guard let recorder, recorder.isRecording else {
            return
        }
        recorder.updateMeters()
        levels.append(Waveform.level(decibels: Double(recorder.averagePower(forChannel: 0))))
    }

    private func stopRecording() {
        metering?.cancel()
        metering = nil
        recorder?.stop()
        recorder = nil
        isRecordingNow.withLock { $0 = false }
    }

    private func throwAway() {
        let file = recorder?.url ?? kept
        stopRecording()
        if let file {
            try? FileManager.default.removeItem(at: file)
        }
        kept = nil
    }

    /// Music stopped for the note carries on, and the next note is readied, both on the
    /// sound's queue, in that order.
    private func readyForTheNext() {
        let isRecordingNow = isRecordingNow
        AudioFocus.soon {
            if !isRecordingNow.withLock({ $0 }) {
                AudioFocus.giveBack()
            }
        }
        if wantsWarmth { warm() }
    }

    private func discardReady() {
        guard let unused = warming else { return }
        warming = nil
        Task {
            if let ready = await unused.value.recorder {
                try? FileManager.default.removeItem(at: ready.url)
            }
        }
    }
}
