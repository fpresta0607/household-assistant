// Whether the microphone has input now. iOS reads the input node's hardware format as a
// sample rate or a channel count of zero while it has none, as while the sound cannot
// record. Input through it then fails, as an error where it can and otherwise as an
// Objective-C exception, which Swift cannot catch. Apple's documentation for
// AVAudioEngine.inputNode says to check this before any input.

import AVFoundation

extension AVAudioInputNode {
    var hasInput: Bool {
        let hardware = inputFormat(forBus: 0)
        return hardware.sampleRate > 0 && hardware.channelCount > 0
    }
}
