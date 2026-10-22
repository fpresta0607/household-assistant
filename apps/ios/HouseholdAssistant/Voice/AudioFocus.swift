// Who has the phone's sound. The app rests ambient, mixing with whatever else is
// playing, so a muted video scrolling by never stops someone's music. Playing a voice
// note or a video with its sound on, recording, or talking takes the sound, and giving
// it back lets the music that was playing carry on. A conversation on screen keeps the
// sound ready for recording, still mixing, so a voice note starts the moment the
// microphone is touched.
//
// A call with the assistant has the sound for as long as it lasts, and nothing else takes
// it or gives it back meanwhile: the call goes on behind the call bar while the person
// moves round the app, and a voice note, a recording or a video's sound started there
// would otherwise set the sound up for itself, or give it back, from under the call. A
// voice note waits for the call, as on an iPhone call.

import AVFoundation
import os

enum AudioFocus {
    /// What `take` throws while a call has the sound.
    enum Refusal: Error {
        case onACall
    }

    /// Whether a call has the sound. Locked, since the call sets it and anything may ask.
    private static let isOnACall = OSAllocatedUnfairLock(initialState: false)

    /// AVAudioSession's calls block while the audio hardware switches, for a moment in the
    /// simulator and for much longer on a phone with headphones or music playing. Whatever
    /// can wait does them here, away from the main actor, in the order it asked (CFO notes
    /// section 21: opening and leaving a conversation, and sending a voice note, waited on them).
    private static let queue = DispatchQueue(label: "household.audio-focus", qos: .userInitiated)

    static func soon(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// How the app starts, and what it returns to whenever it gives the sound back.
    static func rest() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
    }

    static func take(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions = []) throws {
        guard !isOnACall.withLock({ $0 }) else {
            throw Refusal.onACall
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(category, mode: mode, options: options)
        try session.setActive(true)
    }

    /// Sets the sound up for a call with the assistant as the Phone app has it: voice chat,
    /// which the microphone's voice processing and its echo cancellation are made for,
    /// through the iPhone at the ear, its speaker, AirPods, a Bluetooth headset or the car.
    /// It does not mix: music stops for the call, as it does for a phone call, rather than
    /// playing on where the microphone would hear it, and comes back after. With CallKit
    /// the sound is only set up here, and iOS makes it active once it has the call
    /// (SystemCall). From here until `callEnded()` the sound is the call's.
    static func takeForCall(activating: Bool) throws {
        isOnACall.withLock { $0 = true }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        if activating {
            try session.setActive(true)
        }
    }

    /// The call is over, so the sound is anyone's again. Giving it back is for whoever made
    /// it active: iOS does that for a call through CallKit.
    static func callEnded() {
        isOnACall.withLock { $0 = false }
    }

    /// Whether the sound is still set the way it was taken. Anyone else taking it, or
    /// giving it back, changes that.
    static func isHeld(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode) -> Bool {
        let session = AVAudioSession.sharedInstance()
        return session.category == category && session.mode == mode
    }

    /// Whether another app is playing, such as music.
    static var isOtherAudioPlaying: Bool {
        AVAudioSession.sharedInstance().isOtherAudioPlaying
    }

    /// Whether the sound was given back. A session whose sound is still winding down
    /// refuses, and whoever stopped it may try again a moment later. A call's sound is not
    /// given back by anything but the call.
    @discardableResult
    static func giveBack() -> Bool {
        guard !isOnACall.withLock({ $0 }) else {
            return false
        }
        let isGivenBack = (try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)) != nil
        rest()
        return isGivenBack
    }
}
