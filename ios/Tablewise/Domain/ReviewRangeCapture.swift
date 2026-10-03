import Foundation

/// Frozen review context, including missing or unusable assumptions at capture time.
/// Temporary IDs identify embedded snapshots; they are not references to the live plan library.
struct ReviewRangeCapture: Codable, Equatable, Sendable {
    var subjectID: UUID
    var after: Bool
    var reveal: Bool
    var scope: RangePlan.Scope
    var capturedAt: Date = Date()
    var issues: [String] = []
    var temporaryPlanIDs: [UUID] = []
    // Independent historical evidence, never inserted into or resolved against the live library.
    var dependencyPlanSnapshots: [RangePlan]? = nil
    var dependencyEvents: [HandEvent]? = nil
}
