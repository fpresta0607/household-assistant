// OpenRouter's image and video models, for the Model page's Image and Video segments.
//
// Each list is read from the gateway the first time its segment shows and kept while the
// page is open, so nothing is read at launch or for a segment nobody opens. A list that
// could not be read says why in one line, and is read again when asked.

import Foundation
import Observation

@MainActor
@Observable
final class ModelLists {
    enum Status: Equatable, Sendable {
        case reading
        case read([MediaModel])
        /// Why it could not be read, in the gateway's words.
        case failed(String)
    }

    /// Each kind's list, once its segment has asked for it.
    private(set) var status: [ModelKind: Status] = [:]

    /// Reads `kind`'s list, unless it is read already or on its way.
    func load(_ kind: ModelKind, from connection: GatewayConnection) async {
        switch status[kind] {
        case .reading?, .read?:
            return
        case .failed?, nil:
            break
        }
        status[kind] = .reading
        do {
            status[kind] = .read(try await connection.modelChoices(kind))
        } catch {
            status[kind] = .failed(ErrorText.describe(error))
        }
    }

    /// `kind`'s models whose name, company or id has each word of `query`, or every one
    /// but the one in use while it has none.
    func models(_ kind: ModelKind, matching query: String, inUse: String?) -> [MediaModel] {
        guard case .read(let models)? = status[kind] else {
            return []
        }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else {
            return models.filter { $0.id != inUse }
        }
        return models.filter { model in
            let haystack = "\(model.name) \(model.company) \(model.id)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// The model `id` as `kind`'s list has it, for its price, or nil until the list is read
    /// or when it does not have it.
    func listed(_ kind: ModelKind, id: String) -> MediaModel? {
        guard case .read(let models)? = status[kind] else {
            return nil
        }
        return models.first { $0.id == id }
    }
}
