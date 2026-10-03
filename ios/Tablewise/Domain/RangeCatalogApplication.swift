import Foundation

struct RangeCatalogUpdate {
    let plan: RangePlan
    let actionLabel: String
    let sourceName: String
    let changedCombinationCount: Int
}

extension RangeCatalogRepository {
    func hasPackage(_ reference: RangeCatalogReference) -> Bool {
        installed.contains { $0.pack.id == reference.packageId && $0.pack.packageVersion == reference.packageVersion }
    }
    func provenanceIssues(_ reference: RangeCatalogReference) -> [String] {
        guard reference.isValid else { return ["范围来源引用格式无效"] }
        guard let package = installed.first(where: { $0.pack.id == reference.packageId && $0.pack.packageVersion == reference.packageVersion }) else { return ["原审核包未安装，来源暂不可核验"] }
        guard package.release.sha256 == reference.contentHash, package.release.reviewId == reference.reviewId else { return ["来源哈希或审核记录不符"] }
        guard package.release.rangeNodeIds.contains(reference.nodeId) else { return ["来源节点不在审核覆盖清单"] }
        if let action = reference.actionId, let parent = reference.parentNodeId {
            guard package.release.actionLinks.contains(where: { $0.fromNodeId == parent && $0.actionId == action && $0.toNodeId == reference.nodeId }) else { return ["来源行动连接未获审核覆盖"] }
        }
        return []
    }

    /// Verifies the original source and replayable edits; a saved source string alone confers no trust.
    /// Older fact revisions may retain provenance but cannot be used as a current match.
    func referenceIssues(_ reference: RangeCatalogReference, plan: RangePlan, hand: HandRecord) -> [String] {
        let provenance = provenanceIssues(reference)
        guard provenance.isEmpty else { return provenance }
        guard plan.isValidWeights, plan.handID == hand.id, plan.factRevision == hand.revision, plan.removedEvent == nil else { return ["范围事实版本或权重无效；旧来源需重新核对"] }
        guard let package = installed.first(where: { $0.pack.id == reference.packageId && $0.pack.packageVersion == reference.packageVersion }),
              let node = package.pack.nodes.first(where: { $0.id == reference.nodeId }),
              let context = package.pack.contexts.first(where: { $0.id == node.contextId }) else { return ["来源节点引用断裂"] }
        let query = RangeCatalogQuery(hand: hand, eventID: plan.eventID, after: plan.after, targetPlayerID: plan.targetPlayerID, format: hand.gameFormat?.rawValue)
        guard query.missing.isEmpty else { return query.missing }
        let differences = RangeCatalogMatcher.differences(context, targetSourcePlayer: node.playerId, query: query)
        guard differences.isEmpty else { return differences.map { "来源场景不符：" + $0 } }
        var baseline = plan.weights
        for entry in (plan.changeHistory ?? []).reversed() {
            guard Set(entry.changes.map(\.index)).count == entry.changes.count else { return ["来源修订组合重复"] }
            for change in entry.changes {
                guard baseline.indices.contains(change.index), baseline[change.index] == change.after else { return ["来源修订链与当前权重不符"] }
                baseline[change.index] = change.before
            }
        }
        if let action = reference.actionId, let parent = reference.parentNodeId {
            guard plan.after, let parentNode = package.pack.nodes.first(where: { $0.id == parent }),
                  let probability = parentNode.actionPolicy?.byAction[action],
                  let parentContext = package.pack.contexts.first(where: { $0.id == parentNode.contextId }),
                  let definition = parentNode.actionDefinitions.first(where: { $0.id == action }),
                  let actual = query.projection.nodes.first(where: { $0.id == plan.eventID }),
                  actual.event.playerID == plan.targetPlayerID,
                  reference.parentWeightsHash == Self.weightsHash(baseline) else { return ["行动更新先验或模型引用不符"] }
            let before = RangeCatalogQuery(hand: hand, eventID: plan.eventID, after: false, targetPlayerID: plan.targetPlayerID, format: hand.gameFormat?.rawValue)
            let modelAction = RangeCatalogPack.Action(playerId: parentNode.playerId, street: actual.event.street.rawValue,
                kind: definition.kind, amountBb: definition.amountBb, amountMeaning: definition.amountMeaning)
            guard RangeCatalogMatcher.differences(parentContext, targetSourcePlayer: parentNode.playerId, query: before).isEmpty,
                  RangeCatalogMatcher.actionMatches(modelAction, node: actual, bigBlind: Double(hand.configuration.bigBlind)) else {
                return ["行动更新的前序场景或实际行动不符"]
            }
            let expected = zip(baseline, probability).map { weight, frequency -> Double? in
                guard let weight, let frequency else { return nil }; return weight * frequency
            }
            if let modelID = reference.modelChangeID {
                guard let first = plan.changeHistory?.first, first.id == modelID else { return ["缺少行动更新的首笔修订"] }
                var applied = baseline
                for change in first.changes { applied[change.index] = change.after }
                if !Self.sameWeights(applied, expected) { return ["行动后权重未按先验乘已审核概率生成"] }
            } else if !Self.sameWeights(baseline, expected) { return ["非恒等行动更新缺少修订记录"] }
        } else {
            guard let original = node.reachRange?.weights else { return ["来源到达范围缺失"] }
            if !Self.sameWeights(baseline, original.map { $0.map { $0 * 100 } }) { return ["初始权重与审核来源不符"] }
        }
        return []
    }

    /// Display trust is derived from installed evidence and facts, never from a user source string.
    func sourceSummary(plan: RangePlan, hand: HandRecord?) -> String {
        let status: String
        if let reference = plan.catalogReference {
            if let hand, referenceIssues(reference, plan: plan, hand: hand).isEmpty {
                let node = installed.first { $0.pack.id == reference.packageId && $0.pack.packageVersion == reference.packageVersion }?
                    .pack.nodes.first { $0.id == reference.nodeId }
                if reference.actionId != nil { status = "已核验固定行为模型 · 用户先验派生假设，非重新求解" }
                else if node?.quality.origin == "teaching" { status = "已核验教学简化来源 · 用户假设" }
                else { status = "已核验审核参考来源 · 用户假设" }
            } else { status = "来源暂不可核验 · 保留用户假设，不能视为当前审核匹配" }
        } else { status = "用户自定义假设 · 无审核来源引用" }
        let operations = (plan.changeHistory ?? []).compactMap(\.quickAdjustmentReference)
        let quickStatus = operations.isEmpty ? "" : operations.allSatisfy { quickReferenceIssues($0).isEmpty }
            ? "；已核验语义规则 · 调整结果仍是用户假设" : "；语义规则来源暂不可核验 · 保留用户调整假设"
        return status + quickStatus + "；来源原文（用户声明）：" + plan.source
    }

    func hypothesis(from match: RangeCatalogMatch, query: RangeCatalogQuery, subjectID: UUID, reveal: Bool, scope: RangePlan.Scope) throws -> RangePlan {
        var plan = RangePlan(handID: query.hand.id, eventID: query.eventID, subjectID: subjectID, targetPlayerID: query.targetPlayerID,
                             after: query.after, reveal: reveal, factRevision: query.hand.revision,
                             name: "参考 · " + match.sourceName, weights: match.weights,
                             source: "\(match.origin == "teaching" ? "教学简化" : "审核参考") · \(match.sourceName) · \(match.reference.packageVersion)",
                             scope: scope, catalogReference: match.reference)
        plan.isActive = false // Explicit adoption creates a transient hypothesis; persistence remains an explicit save.
        let issues = referenceIssues(match.reference, plan: plan, hand: query.hand)
        guard issues.isEmpty else { throw RangeCatalogError.invalid(issues.joined(separator: "；")) }
        return plan
    }

    /// A reviewed fixed behavior model applied to an explicitly chosen, same-event before-plan.
    /// Unknown prior weights stay unknown; neither normalization nor equilibrium re-solving occurs.
    func updates(prior: RangePlan, after query: RangeCatalogQuery, plans: [RangePlan], savedPlans: [RangePlan], temporaryPlanIDs: Set<UUID>, origin: RangePlanDependency.Origin) throws -> [RangeCatalogUpdate] {
        let dependencyIssues = RangePlanDependencies.issues(for: prior, hand: query.hand, plans: plans, savedPlans: savedPlans, temporaryPlanIDs: temporaryPlanIDs)
        guard dependencyIssues.isEmpty else { throw RangeCatalogError.invalid(dependencyIssues.joined(separator: "；")) }
        guard query.after, prior.handID == query.hand.id, prior.eventID == query.eventID, !prior.after,
              prior.targetPlayerID == query.targetPlayerID, prior.factRevision == query.hand.revision,
              prior.removedEvent == nil, prior.isValidWeights,
              let actual = query.projection.nodes.first(where: { $0.id == query.eventID }), actual.event.playerID == prior.targetPlayerID else {
            throw RangeCatalogError.invalid("行动更新需要同一行动前、同一玩家及当前事实版本的显式先验")
        }
        guard query.missing.isEmpty else { throw RangeCatalogError.invalid(query.missing.joined(separator: "；")) }
        let beforeQuery = RangeCatalogQuery(hand: query.hand, eventID: query.eventID, after: false, targetPlayerID: query.targetPlayerID, format: query.format, payouts: query.payouts)
        let starts = match(beforeQuery).matches
        var output: [RangeCatalogUpdate] = []
        for start in starts {
            guard let package = installed.first(where: { $0.pack.id == start.reference.packageId && $0.pack.packageVersion == start.reference.packageVersion }),
                  let from = package.pack.nodes.first(where: { $0.id == start.reference.nodeId }), let source = package.pack.sources.first(where: { $0.id == from.sourceId }) else { continue }
            for link in package.release.actionLinks where link.fromNodeId == from.id {
                guard let action = from.actionDefinitions.first(where: { $0.id == link.actionId }),
                      let policy = from.actionPolicy?.byAction[link.actionId],
                      let to = package.pack.nodes.first(where: { $0.id == link.toNodeId }),
                      let context = package.pack.contexts.first(where: { $0.id == to.contextId }) else { continue }
                let event = RangeCatalogPack.Action(playerId: from.playerId, street: actual.event.street.rawValue, kind: action.kind, amountBb: action.amountBb, amountMeaning: action.amountMeaning)
                guard RangeCatalogMatcher.actionMatches(event, node: actual, bigBlind: Double(query.hand.configuration.bigBlind)),
                      RangeCatalogMatcher.differences(context, targetSourcePlayer: to.playerId, query: query).isEmpty else { continue }
                let weights = zip(prior.weights, policy).map { weight, frequency -> Double? in
                    guard let weight, let frequency else { return nil }; return weight * frequency
                }
                let changes = weights.indices.compactMap { index -> RangePlanChange.WeightChange? in
                    prior.weights[index] == weights[index] ? nil : .init(index: index, before: prior.weights[index], after: weights[index])
                }
                let edit = changes.isEmpty ? nil : RangePlanChange(factRevision: query.hand.revision,
                    reason: "已审核固定行为模型：\(source.name) · \(action.label)；先验 × 行动概率，非重新求解", changes: changes)
                let reference = RangeCatalogReference(packageId: package.pack.id, packageVersion: package.pack.packageVersion, nodeId: to.id,
                    contentHash: package.release.sha256, reviewId: package.release.reviewId, actionId: action.id, parentNodeId: from.id,
                    parentWeightsHash: Self.weightsHash(prior.weights), modelChangeID: edit?.id)
                // Keep this immutable reference even when later manual edits modify the derived plan.
                let plan = RangePlan(handID: prior.handID, eventID: prior.eventID, subjectID: prior.subjectID, targetPlayerID: prior.targetPlayerID,
                    after: true, reveal: prior.reveal, factRevision: prior.factRevision, name: prior.name + " · " + action.label,
                    weights: weights, source: "固定行为假设 · \(source.name) · \(package.pack.packageVersion)",
                    changeHistory: edit.map { [$0] }, scope: prior.resolvedScope, catalogReference: reference,
                    parentDependency: RangePlanDependency(parent: prior, origin: origin))
                let validation = referenceIssues(reference, plan: plan, hand: query.hand)
                guard validation.isEmpty else { throw RangeCatalogError.invalid(validation.joined(separator: "；")) }
                output.append(.init(plan: plan, actionLabel: action.label, sourceName: source.name, changedCombinationCount: changes.count))
            }
        }
        return output
    }
    static func weightsHash(_ weights: [Double?]) -> String {
        guard let data = try? JSONEncoder().encode(weights) else { return "" }
        return hash(data)
    }
    private static func sameWeights(_ lhs: [Double?], _ rhs: [Double?]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs,rhs).allSatisfy { a,b in
            switch (a,b) {
            case (nil,nil): return true
            case (let a?,let b?): return RangeCatalogMatcher.close(a,b)
            default: return false
            }
        }
    }
}
