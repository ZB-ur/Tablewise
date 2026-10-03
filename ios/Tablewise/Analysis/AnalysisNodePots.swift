import Foundation

struct AnalysisPotLayer {
    let units: Int64
    let eligibleIDs: [UUID]
}
struct AnalysisPotStructure {
    let layers: [AnalysisPotLayer]
    let liveContributions: [UUID: Int64]
    let refundUnits: Int64
}

/// Same dead-money / per-street unmatched-investment convention as HandSettlement,
/// scoped to the selected event prefix rather than the completed hand.
enum AnalysisNodePots {
    static func build(hand: HandRecord, snapshot: HandSnapshot, eventID: UUID?, after: Bool) throws -> AnalysisPotStructure {
        guard !snapshot.blocked, snapshot.pot.certainty == .exact, let totalPot = snapshot.pot.units,
              snapshot.players.allSatisfy({ $0.totalContribution.certainty == .exact && $0.totalContribution.units != nil }) else {
            throw EquityError.invalidRequest
        }
        var prefix = hand
        if let eventID {
            guard let index = hand.events.firstIndex(where: { $0.id == eventID }) else { throw EquityError.invalidRequest }
            prefix.events = Array(hand.events.prefix(index + (after ? 1 : 0)))
        } else { prefix.events = [] }
        let projection = HandReducer.project(prefix)
        // Truncating during forced posts may add an end-of-record "missing blind"
        // issue. That is not a conflict in the selected historical prefix.
        guard projection.nodes.allSatisfy({ $0.issues.isEmpty }) else { throw EquityError.invalidRequest }
        var live = Dictionary(uniqueKeysWithValues: snapshot.players.map { ($0.id, $0.totalContribution.units ?? 0) })
        let eligible = snapshot.players.filter { !$0.folded }.map(\.id)
        var dead: Int64 = 0
        func add(_ a: Int64, _ b: Int64) throws -> Int64 {
            let (sum, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw EquityError.invalidRequest }; return sum
        }
        for node in projection.nodes where node.issues.isEmpty && [.ante, .deadBlind].contains(node.event.kind) {
            guard let id = node.event.playerID, let amount = node.event.amount?.units, amount >= 0,
                  let contributed = live[id], contributed >= amount else { throw EquityError.invalidRequest }
            live[id] = contributed - amount
            dead = try add(dead, amount)
        }
        var refunds: Int64 = 0
        for street in HandStreet.allCases {
            guard let end = projection.nodes.last(where: { $0.after.street == street })?.after else { continue }
            let contributions = end.players.map { ($0.id, $0.streetContribution.units ?? 0) }.sorted { $0.1 > $1.1 }
            guard let largest = contributions.first, largest.1 > 0 else { continue }
            let excess = largest.1 - (contributions.dropFirst().first?.1 ?? 0)
            if excess > 0 {
                guard let contribution = live[largest.0], contribution >= excess else { throw EquityError.invalidRequest }
                live[largest.0] = contribution - excess
                refunds = try add(refunds, excess)
            }
        }
        var layers: [AnalysisPotLayer] = []
        func append(_ units: Int64, _ ids: [UUID]) throws {
            guard !ids.isEmpty else { throw EquityError.invalidRequest }
            if let last = layers.last, Set(last.eligibleIDs) == Set(ids) {
                layers[layers.count - 1] = AnalysisPotLayer(units: try add(last.units, units), eligibleIDs: last.eligibleIDs)
            } else { layers.append(AnalysisPotLayer(units: units, eligibleIDs: ids)) }
        }
        if dead > 0 { try append(dead, eligible.filter { (snapshot.player($0)?.totalContribution.units ?? 0) > 0 }) }
        var previous: Int64 = 0
        for level in Set(live.values.filter { $0 > 0 }).sorted() {
            let payers = live.values.filter { $0 >= level }.count
            let (units, overflow) = (level - previous).multipliedReportingOverflow(by: Int64(payers))
            guard !overflow else { throw EquityError.invalidRequest }
            let qualified = eligible.count == 1 ? eligible : eligible.filter { (live[$0] ?? 0) >= level }
            try append(units, qualified)
            previous = level
        }
        var reconstructed = refunds
        for layer in layers { reconstructed = try add(reconstructed, layer.units) }
        guard reconstructed == totalPot else { throw EquityError.invalidRequest }
        return AnalysisPotStructure(layers: layers, liveContributions: live, refundUnits: refunds)
    }
}
