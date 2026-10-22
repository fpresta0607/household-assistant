// Where the phone keeps the last month the gateway answered with, across launches, so the
// Spend page opens on it at once and reads the gateway's newer one in the background.
//
// A protocol because the phone keeps it in its settings and the tests keep none.

import Foundation

@MainActor
protocol SpendStore: AnyObject {
    var spendReport: SpendReport? { get set }
}
