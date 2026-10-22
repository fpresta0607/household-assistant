// Saving a photo or a video from a conversation to the phone's library. Saving asks only to
// add to Photos; reading the library is the photo keeper's, asked for on its own page
// (PhotoKeeperPage).

import Photos

enum PhotoLibrarySaver {
    /// Nil once it is saved, else a sentence saying why it was not.
    static func save(_ file: URL, isVideo: Bool) async -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return "Allow Steward AI to add to Photos in Settings"
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
                } else {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
                }
            }
            return nil
        } catch {
            return "Photos would not take that one"
        }
    }
}
