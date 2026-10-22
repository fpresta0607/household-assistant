// The system camera, for a photo or a video to send. Whatever it takes is handed back
// once, and nothing when the person cancels.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraPicker: UIViewControllerRepresentable {
    enum Shot {
        case photo(UIImage)
        /// A copy of the recording that is this app's to keep or delete.
        case video(URL)
    }

    /// A photo only, as for a face, and no video.
    var isPhotoOnly = false
    let onFinish: (Shot?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = isPhotoOnly ? [UTType.image.identifier] : [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onFinish: (Shot?) -> Void

        init(onFinish: @escaping (Shot?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let recording = info[.mediaURL] as? URL {
                // The camera's own file can be removed once this returns.
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("camera-\(UUID().uuidString)")
                    .appendingPathExtension(recording.pathExtension)
                onFinish((try? FileManager.default.copyItem(at: recording, to: copy)).map { .video(copy) })
            } else if let image = info[.originalImage] as? UIImage {
                onFinish(.photo(image))
            } else {
                onFinish(nil)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
