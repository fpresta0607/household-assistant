// A video picked from Photos, handed over as a file of this app's own, so its length
// and size can be read before it is sent.

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct PickedMovie: Transferable {
    let file: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.file)
        } importing: { received in
            // The received file is gone once this returns, so it is copied first.
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(file: copy)
        }
    }
}
