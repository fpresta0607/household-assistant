// What deletes photos from the library: on the phone, PhotoLibraryDeleter, which hands them to
// iOS, and iOS asks once more and keeps them in Recently Deleted for 30 days. Only
// CleanOutReview.delete(using:), from the owner's tap, ever calls it.

import Foundation

protocol PhotoDeleting: Sendable {
    func delete(_ ids: [String]) async throws
}
