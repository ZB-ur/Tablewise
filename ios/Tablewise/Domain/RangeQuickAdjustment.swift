import Foundation

/// Release-owned approval for an immutable semantic operation sidecar, independent of range approval.
struct RangeQuickAdjustmentRelease: Decodable {
    let id: String
    let packageVersion: String
    let path: String
    let sha256: String
    let reviewId: String
    let reviewer: String
    let reviewedAt: String
    let reviewEvidence: RangeCatalogPack.File
    let operationIds: [String]
}

struct RangeQuickAdjustmentPack: Decodable {
    let schemaVersion: String
    let id: String
    let packageVersion: String
    let encoding: RangeCatalogPack.Encoding
    let basePackage: Base
    let operations: [Operation]
    struct Base: Decodable { let id: String; let version: String; let sha256: String }
    struct Operation: Decodable {
        enum Prior: String, Decodable { case exact_reference, known_user_hypothesis }
        let id: String
        let title: String
        let explanation: String
        let limitations: String
        let nodeId: String
        let sourceId: String
        let evidence: RangeCatalogPack.Evidence
        let times: [String]
        let perspectives: [String]
        let scopes: [String]
        let priorPolicy: Prior
        let allowZeroIncrease: Bool
        let changes: [Transform]
    }
    struct Transform: Decodable {
        enum Kind: String, Decodable { case set, scale, add }
        let comboIndex: Int
        let kind: Kind
        /// set/add use 0–1 inclusion-weight units; scale is a dimensionless multiplier.
        let value: Double
        func apply(_ percent: Double) -> Double {
            let input = percent / 100
            let output: Double
            switch kind {
            case .set: output = value
            case .scale: output = input * value
            case .add: output = input + value
            }
            return min(1, max(0, output)) * 100
        }
    }
}
struct RangeQuickAdjustmentInstalled {
    let pack: RangeQuickAdjustmentPack
    let release: RangeQuickAdjustmentRelease
    let base: RangeCatalogPack
    let baseRelease: RangeCatalogReleaseIndex.Release
}

/// Optional on old audit entries. A user-supplied reference never confers approval.
struct RangeQuickAdjustmentReference: Codable, Equatable, Sendable {
    let packageId: String
    let packageVersion: String
    let contentHash: String
    let operationId: String
    let reviewId: String
    let basePackageId: String
    let basePackageVersion: String
    let baseContentHash: String
    let nodeId: String
    let inputWeightsHash: String
    let contextKey: String
    let factRevision: Int
    let blockers: [Int]
    var isValid: Bool {
        !packageId.isEmpty && !operationId.isEmpty && !reviewId.isEmpty && !basePackageId.isEmpty && !nodeId.isEmpty && !contextKey.isEmpty &&
        [packageVersion, basePackageVersion].allSatisfy { $0.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil } &&
        [contentHash, baseContentHash, inputWeightsHash].allSatisfy(RangeCatalogRepository.validHash) &&
        (0...1_000_000_000).contains(factRevision) && blockers == Array(Set(blockers)).sorted() && blockers.allSatisfy { (0..<52).contains($0) }
    }
}

struct RangeQuickAdjustmentPreview: Identifiable {
    let id = UUID()
    let original: RangePlan
    let reference: RangeQuickAdjustmentReference
    let title: String
    let explanation: String
    let limitations: String
    let sourceName: String
    let reviewer: String
    let changes: [RangePlanChange.WeightChange]
    let blockedCount: Int
    var weightedDelta: Double { changes.reduce(0) { $0 + (($1.after ?? 0) - ($1.before ?? 0)) / 100 } }
}

extension RangeCatalogRepository {
    static func loadQuickAdjustment(_ entry: RangeQuickAdjustmentRelease, base: RangeCatalogPack,
                                    release: RangeCatalogReleaseIndex.Release, readResource: (String) throws -> Data) throws -> RangeQuickAdjustmentInstalled {
        func require(_ yes: Bool, _ reason: String) throws { if !yes { throw RangeCatalogError.invalid(reason) } }
        try require(safePath(entry.path) && validHash(entry.sha256) && !entry.reviewId.isEmpty && !entry.reviewer.isEmpty &&
                    ISO8601DateFormatter().date(from: entry.reviewedAt) != nil && safePath(entry.reviewEvidence.path) && validHash(entry.reviewEvidence.sha256), "快捷操作审核证据或身份不完整")
        let evidence = try readResource(entry.reviewEvidence.path)
        try require(!evidence.isEmpty && evidence.count <= 4 * 1_024 * 1_024 && hash(evidence) == entry.reviewEvidence.sha256, "快捷操作审核证据哈希不符")
        let raw = try readResource(entry.path)
        try require(raw.count <= 4 * 1_024 * 1_024 && hash(raw) == entry.sha256, "快捷操作内容哈希或大小不符")
        let pack = try JSONDecoder().decode(RangeQuickAdjustmentPack.self, from: raw)
        try require(pack.schemaVersion == "1.0.0" && pack.encoding.id == "holdem-1326-cdhs-v1" && pack.id == entry.id &&
                    pack.packageVersion == entry.packageVersion && !pack.id.isEmpty &&
                    pack.packageVersion.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil, "快捷操作格式或版本不符")
        try require(pack.basePackage.id == base.id && pack.basePackage.version == base.packageVersion && pack.basePackage.sha256 == release.sha256, "快捷操作基础包依赖不符")
        try require(!pack.operations.isEmpty && pack.operations.count <= 100 && Set(pack.operations.map(\.id)).count == pack.operations.count &&
                    !entry.operationIds.isEmpty && Set(entry.operationIds).count == entry.operationIds.count && Set(entry.operationIds).isSubset(of: Set(pack.operations.map(\.id))), "快捷操作批准覆盖或ID无效")
        for operation in pack.operations {
            guard let node = base.nodes.first(where: { $0.id == operation.nodeId }), let source = base.sources.first(where: { $0.id == operation.sourceId }) else {
                throw RangeCatalogError.invalid("快捷操作节点或来源断裂")
            }
            try require(!operation.id.isEmpty && !operation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        !operation.explanation.isEmpty && !operation.limitations.isEmpty && node.sourceId == source.id && release.rangeNodeIds.contains(node.id) &&
                        source.files.contains(where: { $0.path == operation.evidence.sourceFile }) && !operation.evidence.derivation.isEmpty, "快捷操作缺语义、限制或已核验节点/来源证据")
            try require(validOptions(operation.times, allowed: ["before", "after"]) && validOptions(operation.perspectives, allowed: ["decision", "revealed"]) &&
                        validOptions(operation.scopes, allowed: ["decision", "fullRangeResearch"]), "快捷操作适用边界缺失或无效")
            try require(!operation.changes.isEmpty && operation.changes.count <= 1326 && Set(operation.changes.map(\.comboIndex)).count == operation.changes.count &&
                        operation.changes.allSatisfy { item in
                            guard (0..<1326).contains(item.comboIndex), item.value.isFinite else { return false }
                            switch item.kind { case .set: return (0...1).contains(item.value); case .scale: return (0...100).contains(item.value); case .add: return (-1...1).contains(item.value) }
                        }, "快捷操作组合或变换参数无效")
        }
        return .init(pack: pack, release: entry, base: base, baseRelease: release)
    }
    private static func validOptions(_ values: [String], allowed: Set<String>) -> Bool {
        !values.isEmpty && Set(values).count == values.count && Set(values).isSubset(of: allowed)
    }
    func quickPreviews(plan: RangePlan, hand: HandRecord, blockers: Set<Int>, plans: [RangePlan], savedPlans: [RangePlan], temporaryPlanIDs: Set<UUID>) -> [RangeQuickAdjustmentPreview] {
        quickAdjustments.flatMap { installed in
            installed.pack.operations.filter { installed.release.operationIds.contains($0.id) }.compactMap { operation in
                try? quickPreview(installed: installed, operation: operation, plan: plan, hand: hand, blockers: blockers, plans: plans, savedPlans: savedPlans, temporaryPlanIDs: temporaryPlanIDs)
            }
        }
    }
    private func quickPreview(installed: RangeQuickAdjustmentInstalled, operation: RangeQuickAdjustmentPack.Operation,
                              plan: RangePlan, hand: HandRecord, blockers: Set<Int>, plans: [RangePlan], savedPlans: [RangePlan], temporaryPlanIDs: Set<UUID>) throws -> RangeQuickAdjustmentPreview {
        let dependency = RangePlanDependencies.issues(for: plan, hand: hand, plans: plans, savedPlans: savedPlans, temporaryPlanIDs: temporaryPlanIDs)
        guard dependency.isEmpty, operation.times.contains(plan.after ? "after" : "before"), operation.perspectives.contains(plan.reveal ? "revealed" : "decision"),
              operation.scopes.contains(plan.resolvedScope.rawValue),
              let node = installed.base.nodes.first(where: { $0.id == operation.nodeId }), let context = installed.base.contexts.first(where: { $0.id == node.contextId }) else {
            throw RangeCatalogError.invalid("快捷操作与当前有效假设的时点、视角或口径不符")
        }
        let query = RangeCatalogQuery(hand: hand, eventID: plan.eventID, after: plan.after, targetPlayerID: plan.targetPlayerID, format: hand.gameFormat?.rawValue)
        guard query.missing.isEmpty, RangeCatalogMatcher.differences(context, targetSourcePlayer: node.playerId, query: query).isEmpty,
              plan.weights.indices.allSatisfy({ RangePlan.combinations[$0].blocked(by: blockers) || plan.weights[$0] != nil }) else {
            throw RangeCatalogError.invalid("快捷操作场景未精确覆盖或合法先验仍未知")
        }
        guard let snapshot = query.snapshot else { throw RangeCatalogError.invalid("快捷操作节点不存在") }
        var visibleCards = snapshot.board
        if plan.resolvedScope == .decision {
            for player in hand.players where player.id != plan.targetPlayerID && (plan.reveal || player.id == plan.subjectID) { visibleCards += player.holeCards }
        }
        guard Set(visibleCards.map(\.analysisIndex)) == blockers else { throw RangeCatalogError.invalid("快捷操作阻断牌与当前可见事实不符") }
        if operation.priorPolicy == .exact_reference {
            guard let reference = node.reachRange?.weights, zip(plan.weights, reference).allSatisfy({ lhs, rhs in
                guard let lhs, let rhs else { return lhs == nil && rhs == nil }; return RangeCatalogMatcher.close(lhs, rhs * 100)
            }) else { throw RangeCatalogError.invalid("快捷操作只审核适用于原参考权重") }
        }
        var changes: [RangePlanChange.WeightChange] = [], blocked = 0
        for transform in operation.changes {
            let index = transform.comboIndex
            if RangePlan.combinations[index].blocked(by: blockers) { blocked += 1; continue }
            guard let before = plan.weights[index] else { throw RangeCatalogError.invalid("快捷操作目标先验未知") }
            let after = transform.apply(before)
            guard operation.allowZeroIncrease || before != 0 || after == 0 else { throw RangeCatalogError.invalid("快捷操作未获准重新纳入排除组合") }
            if before != after { changes.append(.init(index: index, before: before, after: after)) }
        }
        guard !changes.isEmpty else { throw RangeCatalogError.invalid("快捷操作没有合法组合权重变化") }
        let reference = RangeQuickAdjustmentReference(packageId: installed.pack.id, packageVersion: installed.pack.packageVersion, contentHash: installed.release.sha256,
            operationId: operation.id, reviewId: installed.release.reviewId, basePackageId: installed.base.id, basePackageVersion: installed.base.packageVersion,
            baseContentHash: installed.baseRelease.sha256, nodeId: node.id, inputWeightsHash: Self.weightsHash(plan.weights), contextKey: plan.contextKey,
            factRevision: plan.factRevision, blockers: blockers.sorted())
        return .init(original: plan, reference: reference, title: operation.title, explanation: operation.explanation, limitations: operation.limitations,
                     sourceName: installed.base.sources.first(where: { $0.id == operation.sourceId })!.name,
                     reviewer: installed.release.reviewer, changes: changes.sorted { $0.index < $1.index }, blockedCount: blocked)
    }
    func applyQuickPreview(_ preview: RangeQuickAdjustmentPreview, plan: RangePlan, hand: HandRecord, blockers: Set<Int>, plans: [RangePlan], savedPlans: [RangePlan], temporaryPlanIDs: Set<UUID>) throws -> RangePlan {
        guard plan == preview.original, blockers.sorted() == preview.reference.blockers,
              let installed = quickAdjustments.first(where: { $0.pack.id == preview.reference.packageId && $0.pack.packageVersion == preview.reference.packageVersion && $0.release.sha256 == preview.reference.contentHash && $0.release.reviewId == preview.reference.reviewId }),
              installed.release.operationIds.contains(preview.reference.operationId),
              let operation = installed.pack.operations.first(where: { $0.id == preview.reference.operationId }) else {
            throw RangeCatalogError.invalid("预览输入或审核来源已变化，请重新检查")
        }
        let fresh = try quickPreview(installed: installed, operation: operation, plan: plan, hand: hand, blockers: blockers, plans: plans, savedPlans: savedPlans, temporaryPlanIDs: temporaryPlanIDs)
        guard fresh.reference == preview.reference, fresh.changes == preview.changes else { throw RangeCatalogError.invalid("预览已失效，请重新检查") }
        var result = plan
        for change in fresh.changes { result.weights[change.index] = change.after }
        let change = RangePlanChange(factRevision: hand.revision, reason: "审核语义操作：" + fresh.title + " · 用户假设，非重新求解", changes: fresh.changes, quickAdjustmentReference: fresh.reference)
        result.changeHistory = (result.changeHistory ?? []) + [change]
        return result
    }

    /// Missing sidecars preserve user hypotheses; installed identities must agree with their evidence.
    func quickReferenceIssues(_ reference: RangeQuickAdjustmentReference) -> [String] {
        guard reference.isValid else { return ["快捷操作来源引用格式无效"] }
        guard let installed = quickAdjustments.first(where: { $0.pack.id == reference.packageId && $0.pack.packageVersion == reference.packageVersion }) else { return ["原审核语义操作包未安装，来源暂不可核验"] }
        guard installed.release.sha256 == reference.contentHash && installed.release.reviewId == reference.reviewId &&
              installed.base.id == reference.basePackageId && installed.base.packageVersion == reference.basePackageVersion && installed.baseRelease.sha256 == reference.baseContentHash &&
              installed.release.operationIds.contains(reference.operationId) && installed.pack.operations.contains(where: { $0.id == reference.operationId && $0.nodeId == reference.nodeId }) else {
            return ["快捷操作来源哈希、依赖或审核覆盖不符"]
        }
        return []
    }
    /// Replays stored numeric edits against trusted operations; historical facts are optional on recovery.
    func quickChangeIssues(_ reference: RangeQuickAdjustmentReference, entry: RangePlanChange, input: [Double?], plan: RangePlan, hand: HandRecord?) -> [String] {
        let provenance = quickReferenceIssues(reference)
        guard provenance.isEmpty else { return provenance }
        guard let installed = quickAdjustments.first(where: { $0.pack.id == reference.packageId && $0.pack.packageVersion == reference.packageVersion }),
              let operation = installed.pack.operations.first(where: { $0.id == reference.operationId }),
              input.count == 1326, reference.contextKey == plan.contextKey, reference.factRevision == entry.factRevision,
              reference.inputWeightsHash == Self.weightsHash(input),
              operation.times.contains(plan.after ? "after" : "before"), operation.perspectives.contains(plan.reveal ? "revealed" : "decision"),
              operation.scopes.contains(plan.resolvedScope.rawValue),
              let node = installed.base.nodes.first(where: { $0.id == operation.nodeId }),
              let context = installed.base.contexts.first(where: { $0.id == node.contextId }) else { return ["快捷操作历史适用边界或先验不符"] }
        let blockers = Set(reference.blockers)
        guard input.indices.allSatisfy({ RangePlan.combinations[$0].blocked(by: blockers) || input[$0] != nil }) else { return ["快捷操作历史合法先验未知"] }
        if operation.priorPolicy == .exact_reference {
            guard let original = node.reachRange?.weights, zip(input, original).allSatisfy({ lhs, rhs in
                guard let lhs, let rhs else { return lhs == nil && rhs == nil }; return RangeCatalogMatcher.close(lhs, rhs * 100)
            }) else { return ["快捷操作历史不符合原参考先验要求"] }
        }
        var expected: [RangePlanChange.WeightChange] = []
        for transform in operation.changes where !RangePlan.combinations[transform.comboIndex].blocked(by: blockers) {
            guard let before = input[transform.comboIndex] else { return ["快捷操作历史目标先验未知"] }
            let after = transform.apply(before)
            guard operation.allowZeroIncrease || before != 0 || after == 0 else { return ["快捷操作历史擅自纳入排除组合"] }
            if before != after { expected.append(.init(index: transform.comboIndex, before: before, after: after)) }
        }
        guard expected.sorted(by: { $0.index < $1.index }) == entry.changes else { return ["快捷操作历史不符合审核变换"] }
        if let hand {
            let query = RangeCatalogQuery(hand: hand, eventID: plan.eventID, after: plan.after, targetPlayerID: plan.targetPlayerID, format: hand.gameFormat?.rawValue)
            guard hand.revision == reference.factRevision, query.missing.isEmpty,
                  RangeCatalogMatcher.differences(context, targetSourcePlayer: node.playerId, query: query).isEmpty, let snapshot = query.snapshot else {
                return ["快捷操作历史场景不在审核精确覆盖"]
            }
            var cards = snapshot.board
            if plan.resolvedScope == .decision {
                for player in hand.players where player.id != plan.targetPlayerID && (plan.reveal || player.id == plan.subjectID) { cards += player.holeCards }
            }
            guard Set(cards.map(\.analysisIndex)) == blockers else { return ["快捷操作历史阻断证据与事实不符"] }
        }
        return []
    }
    func hasQuickPackage(_ reference: RangeQuickAdjustmentReference) -> Bool {
        quickAdjustments.contains { $0.pack.id == reference.packageId && $0.pack.packageVersion == reference.packageVersion }
    }
}

extension RangePlan {
    /// Only F06 operations are persisted here. Later manual edits must be undone first.
    var latestUndoableChange: RangePlanChange? {
        let history = changeHistory ?? []
        var undone = Set<UUID>()
        for entry in history.reversed() {
            if let id = entry.undoOfChangeID { undone.insert(id); continue }
            if undone.contains(entry.id) { continue }
            return entry
        }
        return nil
    }
    var undoableQuickChange: RangePlanChange? {
        guard let entry = latestUndoableChange, entry.quickAdjustmentReference != nil else { return nil }
        return entry
    }
    func undoQuickChange() throws -> RangePlan {
        guard let change = undoableQuickChange,
              change.changes.allSatisfy({ weights[$0.index] == $0.after }) else { throw RangeCatalogError.invalid("后续修改须先撤销，不能覆盖当前权重") }
        var result = self
        let inverse = change.changes.map { RangePlanChange.WeightChange(index: $0.index, before: $0.after, after: $0.before) }
        for item in inverse { result.weights[item.index] = item.after }
        result.changeHistory = (changeHistory ?? []) + [RangePlanChange(factRevision: factRevision, reason: "撤销审核语义操作 · " + change.reason, changes: inverse, undoOfChangeID: change.id)]
        return result
    }
}
