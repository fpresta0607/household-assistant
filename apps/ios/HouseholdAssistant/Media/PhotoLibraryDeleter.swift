// The clean-out's delete, from the owner's tap on its batch alone (CleanOutReview): the
// chosen photos go to iOS in one change, iOS asks the owner once more in its own words, and
// keeps them in Recently Deleted for 30 days, where they can be put back.

import Photos

struct PhotoLibraryDeleter: PhotoDeleting {
    func delete(_ ids: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}
