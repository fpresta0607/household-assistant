// iOS's own list of where a call's sound goes, AirPods, the car, the speaker or the iPhone,
// laid unseen over the Audio button while something connected has the sound, as an iPhone
// call's Audio button offers it. The call follows whatever is picked (CallAudio).

import AVKit
import SwiftUI

struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        // The button under it is what shows; the picker only takes the tap.
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
