import Foundation

/// A user hypothesis, independent of recorded hole cards. Nil is unknown, zero is excluded.
struct RangePlan: Codable, Equatable, Identifiable, Sendable {
    enum Scope: String, Codable, Sendable { case decision, fullRangeResearch }
    var id: UUID = UUID()
    var handID: UUID
    var eventID: UUID
    var subjectID: UUID
    var targetPlayerID: UUID
    var after: Bool
    var reveal: Bool
    var factRevision: Int
    var name: String
    var weights: [Double?] = Array(repeating: nil, count: 1326)
    var isActive: Bool = false
    var revision: Int = 0
    var source: String = "用户自定义假设"
    var updatedAt: Date = Date()
    var removedEvent: HandEvent? = nil
    // Optional additions preserve decoding of plans saved before learning/audit support.
    var changeHistory: [RangePlanChange]? = nil
    var judgment: String? = nil
    var question: String? = nil
    var judgmentRecordedAt: Date? = nil
    var scope: Scope? = nil
    var catalogReference: RangeCatalogReference? = nil
    var parentDependency: RangePlanDependency? = nil
    var resolvedScope: Scope { scope ?? .decision }

    var contextKey: String {
        Self.contextKey(handID: handID, eventID: eventID, subjectID: subjectID, targetPlayerID: targetPlayerID, after: after, reveal: reveal, scope: resolvedScope)
    }
    static func contextKey(handID: UUID, eventID: UUID, subjectID: UUID, targetPlayerID: UUID, after: Bool, reveal: Bool, scope: Scope = .decision) -> String {
        "\(handID)|\(eventID)|\(subjectID)|\(targetPlayerID)|\(after)|\(reveal)" + (scope == .fullRangeResearch ? "|fullRangeResearch" : "")
    }

    var isValidWeights: Bool {
        weights.count == 1326 && weights.allSatisfy { $0.map { $0.isFinite && (0...100).contains($0) } ?? true }
    }
    func matches(handID: UUID, eventID: UUID, subjectID: UUID, targetPlayerID: UUID, after: Bool, reveal: Bool, scope: Scope = .decision) -> Bool {
        self.handID == handID && self.eventID == eventID && self.subjectID == subjectID && self.targetPlayerID == targetPlayerID && self.after == after && self.reveal == reveal && resolvedScope == scope
    }
    /// Rank-major card index: 2c,2d,2h,2s,...,Ac,Ad,Ah,As. Every pair i<j appears once.
    static let combinations: [RangePlanCombo] = (0..<51).flatMap { first in
        ((first + 1)..<52).map { second in RangePlanCombo(first: first, second: second) }
    }
    static let categories: [String] = (0..<13).flatMap { row in
        (0..<13).map { column in
            let a = rankLabel(14 - min(row, column)), b = rankLabel(14 - max(row, column))
            return a + b + (row == column ? "" : row < column ? "s" : "o")
        }
    }
    static let categoryIndices: [String: [Int]] = Dictionary(grouping: combinations.indices, by: { combinations[$0].category })
    static func rankLabel(_ rank: Int) -> String { [14: "A", 13: "K", 12: "Q", 11: "J", 10: "T"][rank] ?? String(rank) }
}

struct RangePlanCombo: Hashable, Sendable {
    let first: Int
    let second: Int
    var cards: [PokerCard] { [first, second].map { PokerCard(rank: $0 / 4 + 2, suit: CardSuit.allCases[$0 % 4]) } }
    var category: String {
        let a = first / 4 + 2, b = second / 4 + 2
        return RangePlan.rankLabel(max(a,b)) + RangePlan.rankLabel(min(a,b)) + (a == b ? "" : first % 4 == second % 4 ? "s" : "o")
    }
    func blocked(by cards: Set<Int>) -> Bool { cards.contains(first) || cards.contains(second) }
}

struct RangePlanChange: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var date: Date = Date()
    var factRevision: Int
    var reason: String
    var changes: [WeightChange]
    var quickAdjustmentReference: RangeQuickAdjustmentReference? = nil
    var undoOfChangeID: UUID? = nil
    struct WeightChange: Codable, Equatable, Sendable {
        var index: Int
        var before: Double?
        var after: Double?
    }
}

/// A binding to the exact explicitly chosen prior, not to the catalog's model node.
/// Optional on RangePlan for old backups: old manual hypotheses stay independent.
struct RangePlanDependency: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable { case saved, temporary }
    var parentID: UUID
    var parentRevision: Int
    var parentFactRevision: Int
    var parentContextKey: String
    var parentWeightsHash: String
    var origin: Origin
    init(parent: RangePlan, origin: Origin) {
        parentID = parent.id; parentRevision = parent.revision; parentFactRevision = parent.factRevision
        parentContextKey = parent.contextKey; parentWeightsHash = RangeCatalogRepository.weightsHash(parent.weights)
        self.origin = origin
    }
    var isValid: Bool {
        (0...1_000_000_000).contains(parentRevision) && (0...1_000_000_000).contains(parentFactRevision)
            && !parentContextKey.isEmpty && parentWeightsHash.count == 64
            && parentWeightsHash.allSatisfy { $0.isHexDigit }
    }
}

enum RangePlanDependencies {
    /// Drafts shadow their own saved identity. They never silently fall back to saved weights.
    static func environment(saved: [RangePlan], temporary: [RangePlan]) -> [RangePlan] {
        var values = saved
        for plan in temporary { values.removeAll { $0.id == plan.id }; values.append(plan) }
        return values
    }
    static func issues(for plan: RangePlan, hand: HandRecord, plans: [RangePlan], savedPlans: [RangePlan]? = nil, temporaryPlanIDs: Set<UUID>? = nil) -> [String] {
        func visit(_ current: RangePlan, path: Set<UUID>) -> [String] {
            guard !path.contains(current.id) else { return ["范围依赖出现循环，需重新建立先验"] }
            guard current.factRevision == hand.revision, current.removedEvent == nil,
                  current.handID == hand.id, current.isValidWeights else {
                return ["前序或当前方案的事实版本、节点或权重已失效"]
            }
            guard let binding = current.parentDependency else {
                return current.catalogReference?.actionId == nil ? [] : ["旧行动派生方案未记录用户先验身份，需核对并重新生成"]
            }
            guard binding.isValid else { return ["先验依赖记录格式无效"] }
            if binding.origin == .temporary, let temporaryPlanIDs, !temporaryPlanIDs.contains(binding.parentID) {
                return ["临时先验已不在当前编辑上下文；请重新选择先验并生成"]
            }
            if binding.origin == .saved, let savedPlans {
                guard let saved = savedPlans.first(where: { $0.id == binding.parentID }) else {
                    return ["已保存的先验已删除；残留临时草稿不替代原方案，请重新选择并生成"]
                }
                guard saved.revision == binding.parentRevision, saved.factRevision == binding.parentFactRevision,
                      saved.contextKey == binding.parentContextKey, saved.removedEvent == nil,
                      RangeCatalogRepository.weightsHash(saved.weights) == binding.parentWeightsHash else {
                    return ["已保存的先验已变化，后序假设失效；请用当前先验显式重新生成"]
                }
            }
            let matches = plans.filter { $0.id == binding.parentID }
            guard matches.count == 1, let parent = matches.first else {
                return [binding.origin == .temporary ? "临时先验已缺失；请重新选择当前先验并生成" : "已保存的先验已删除或身份冲突；请重新选择并生成"]
            }
            guard !path.union([current.id]).contains(parent.id) else { return ["范围依赖出现循环，需重新建立先验"] }
            guard parent.handID == current.handID,
                  parent.subjectID == current.subjectID, parent.targetPlayerID == current.targetPlayerID,
                  parent.reveal == current.reveal, parent.resolvedScope == current.resolvedScope,
                  parent.contextKey == binding.parentContextKey else { return ["前序方案的节点、玩家、视角或研究口径不符"] }
            let events = hand.events.map(\.id)
            guard let parentIndex = events.firstIndex(of: parent.eventID), let childIndex = events.firstIndex(of: current.eventID),
                  parentIndex < childIndex || (parentIndex == childIndex && !parent.after && current.after) else {
                return ["先验不是此方案之前的有效行动节点"]
            }
            guard parent.revision == binding.parentRevision, parent.factRevision == binding.parentFactRevision,
                  RangeCatalogRepository.weightsHash(parent.weights) == binding.parentWeightsHash else {
                return ["前序方案已变化，后序假设失效；请用当前先验显式重新生成"]
            }
            return visit(parent, path: path.union([current.id]))
        }
        var cursor = plan, seen = Set<UUID>()
        while let binding = cursor.parentDependency {
            guard seen.insert(cursor.id).inserted, !seen.contains(binding.parentID) else {
                return ["范围依赖出现循环，需重新建立先验"]
            }
            guard let parent = plans.first(where: { $0.id == binding.parentID }) else { break }
            cursor = parent
        }
        return visit(plan, path: [])
    }
    /// Freeze ancestors separately from selected node hypotheses. Missing parents stay missing.
    static func ancestors(of selected: [RangePlan], plans: [RangePlan]) -> [RangePlan] {
        var seen = Set(selected.map(\.id)), result: [RangePlan] = []
        func visit(_ plan: RangePlan) {
            guard let id = plan.parentDependency?.parentID, seen.insert(id).inserted,
                  let parent = plans.first(where: { $0.id == id }) else { return }
            result.append(parent); visit(parent)
        }
        selected.forEach(visit)
        return result.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
