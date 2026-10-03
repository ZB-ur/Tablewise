import Foundation

struct RangeAnalysisInput {
    let request: EquityRequest
    let callPrice: PokerMath.CallPrice?
    let priceRestriction: String
    let assumptions: [String]
}
enum RangeAnalysisInputError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let value) = self { return value }; return nil }
}

/// Shared D04 inputs for node analysis, sensitivity comparison and explicitly labelled
/// full-range research. Every override is a user-selected hypothesis, never an inferred plan.
enum RangeAnalysisContext {
    static func build(hand: HandRecord, snapshot: HandSnapshot, subjectID: UUID, eventID: UUID?,
                      after: Bool, reveal: Bool, plans: [RangePlan], overrides: [UUID: RangePlan] = [:],
                      fullRanges: Bool = false, savedPlans: [RangePlan]? = nil, temporaryPlanIDs: Set<UUID> = []) throws -> RangeAnalysisInput {
        let active = snapshot.players.filter { !$0.folded }
        let scope: RangePlan.Scope = fullRanges ? .fullRangeResearch : .decision
        func index(_ card: PokerCard) -> Int { (card.rank - 2) * 4 + (CardSuit.allCases.firstIndex(of: card.suit) ?? 0) }
        guard !snapshot.blocked else { throw RangeAnalysisInputError.invalid("当前节点有冲突，计算暂停") }
        guard active.count >= 2 else { throw RangeAnalysisInputError.invalid("仅剩一位未弃牌玩家，无需计算对手权益") }
        guard snapshot.player(subjectID) != nil else { throw RangeAnalysisInputError.invalid("分析对象不在当前节点") }
        func playerName(_ id: UUID) -> String { hand.players.first { $0.id == id }?.name ?? "玩家" }
        var assumptions: [String] = []
        let players = try active.map { state -> EquityPlayer in
            let known = hand.players.first { $0.id == state.id }?.holeCards ?? []
            if !fullRanges, (reveal || state.id == subjectID), known.count == 2 {
                assumptions.append("\(playerName(state.id)) · 当前视角已知手牌")
                return EquityPlayer(id: state.id.uuidString, range: [WeightedCombo(index(known[0]), index(known[1]))])
            }
            guard let eventID else { throw RangeAnalysisInputError.invalid("尚未选择行动节点，范围待设定") }
            let candidates: [RangePlan]
            if let override = overrides[state.id] { candidates = [override] }
            else {
                candidates = plans.filter {
                    $0.isActive && $0.matches(handID: hand.id, eventID: eventID, subjectID: subjectID,
                                             targetPlayerID: state.id, after: after, reveal: reveal, scope: scope)
                }
            }
            guard candidates.count == 1 else {
                throw RangeAnalysisInputError.invalid("\(playerName(state.id))：\(candidates.isEmpty ? "尚未明确选择范围方案" : "范围选择冲突")")
            }
            let plan = candidates[0]
            guard plan.matches(handID: hand.id, eventID: eventID, subjectID: subjectID, targetPlayerID: state.id, after: after, reveal: reveal, scope: scope),
                  plan.factRevision == hand.revision, plan.removedEvent == nil else {
                throw RangeAnalysisInputError.invalid("\(plan.name)：节点、视角或事实版本不匹配，请核对范围")
            }
            guard plan.isValidWeights else { throw RangeAnalysisInputError.invalid("\(plan.name)：组合权重无效") }
            let dependencyIssues = RangePlanDependencies.issues(for: plan, hand: hand, plans: plans, savedPlans: savedPlans, temporaryPlanIDs: temporaryPlanIDs)
            guard dependencyIssues.isEmpty else { throw RangeAnalysisInputError.invalid(plan.name + "：" + dependencyIssues.joined(separator: "；")) }
            // Only unknown weights on cards that can actually be dealt are missing.
            // Full-range research deliberately ignores ALL recorded hole cards.
            let visibleOtherCards = fullRanges ? [] : hand.players.filter {
                $0.id != state.id && (reveal || $0.id == subjectID)
            }.flatMap { $0.holeCards.map(index) }
            let blockers = Set(snapshot.board.map(index) + visibleOtherCards)
            let requiredOwnCards = !fullRanges && (reveal || state.id == subjectID) ? known.map(index) : []
            func possible(_ combo: RangePlanCombo) -> Bool {
                !combo.blocked(by: blockers) && requiredOwnCards.allSatisfy { $0 == combo.first || $0 == combo.second }
            }
            guard zip(RangePlan.combinations, plan.weights).allSatisfy({ combo, weight in !possible(combo) || weight != nil }) else {
                throw RangeAnalysisInputError.invalid("\(plan.name)：仍有合法组合的权重未知")
            }
            assumptions.append("\(playerName(state.id)) · \(plan.name) v\(plan.revision) · \(RangeCatalogRepository.bundled.sourceSummary(plan: plan, hand: hand)) · 事实 v\(plan.factRevision)")
            let range = zip(RangePlan.combinations, plan.weights).map { combo, weight in
                // Nil becomes zero ONLY after that specific combo is proven impossible;
                // legal nil was rejected above. One recorded own card must be in the hand.
                let containsRequired = requiredOwnCards.allSatisfy { $0 == combo.first || $0 == combo.second }
                return WeightedCombo(combo.first, combo.second, weight: containsRequired ? weight ?? 0 : 0)
            }
            return EquityPlayer(id: state.id.uuidString, range: range)
        }
        let dead = !fullRanges ? snapshot.players.filter { $0.folded && (reveal || $0.id == subjectID) }.flatMap { state in
            // The decision subject's own known cards remain occupied after folding.
            // Other players' folded cards are visible only in reveal mode.
            hand.players.first { $0.id == state.id }?.holeCards.map(index) ?? []
        } : []
        guard !snapshot.hasUncertainty else { throw RangeAnalysisInputError.invalid("金额有未知或近似项，池资格待核对") }
        let structure = try AnalysisNodePots.build(hand: hand, snapshot: snapshot, eventID: eventID, after: after)
        var pots = structure.layers.enumerated().map { index, layer in
            EquityPot(id: index == 0 ? "主池" : "边池 \(index)", eligiblePlayerIDs: layer.eligibleIDs.map(\.uuidString))
        }
        if pots.isEmpty { pots = [.init(id: "当前手牌对比（尚无可分配底池）", eligiblePlayerIDs: players.map(\.id))] }
        let request = EquityRequest(players: players, board: snapshot.board.map(index), deadCards: dead, pots: pots)
        let price = conditionalPrice(hand: hand, snapshot: snapshot, subjectID: subjectID, eventID: eventID,
                                     after: after, fullRanges: fullRanges, pots: pots)
        return RangeAnalysisInput(request: request, callPrice: price.0, priceRestriction: price.1, assumptions: assumptions)
    }

    static func fingerprint(plans: [RangePlan]) -> String {
        let identities = plans.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            RangeCalculationIdentity(id: $0.id, contextKey: $0.contextKey, factRevision: $0.factRevision,
                                     revision: $0.revision, weights: $0.weights, source: $0.source, name: $0.name,
                                     isActive: $0.isActive, removedEventID: $0.removedEvent?.id, parentDependency: $0.parentDependency, catalogReference: $0.catalogReference)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(identities).base64EncodedString()) ?? "invalid-range-data"
    }

    private static func conditionalPrice(hand: HandRecord, snapshot: HandSnapshot, subjectID: UUID,
                                         eventID: UUID?, after: Bool, fullRanges: Bool, pots: [EquityPot]) -> (PokerMath.CallPrice?, String) {
        guard !fullRanges else { return (nil, "完整范围研究不冒充当前具体手牌的决策 EV") }
        guard !hand.potNeedsReconciliation(nodeEventID: eventID, after: after) else { return (nil, "记忆底池与推导底池有差异，有限 EV 待核对") }
        let active = snapshot.players.filter { !$0.folded }
        guard active.count == 2, !snapshot.roundComplete, !snapshot.handComplete,
              snapshot.actorID == subjectID, !snapshot.hasUncertainty, !snapshot.blocked,
              let own = snapshot.player(subjectID), !own.folded, !own.allIn,
              let opponent = active.first(where: { $0.id != subjectID }),
              let paid = own.streetContribution.units, let remaining = own.remaining.units,
              let opponentPaid = opponent.streetContribution.units,
              let pot = snapshot.pot.units, pots.count == 1,
              Set(pots[0].eligiblePlayerIDs) == Set(active.map { $0.id.uuidString }) else {
            return (nil, "有限跟注 EV 需要双人、轮到自己完整跟注关闭行动、相同池资格且无后续投入；多人或不同边池资格不套统一公式")
        }
        // On the river a complete call closes the final betting round. On preflop/flop/turn
        // it also ends all possible investment when the only opponent is already
        // all-in at an exact zero balance; remaining public cards are still run out
        // by the equity engine rather than treated as known or omitted.
        let earlyStreetAllIn = (snapshot.street == .preflop || snapshot.street == .flop || snapshot.street == .turn)
            && opponent.allIn && opponent.remaining.units == 0
        guard snapshot.street == .river || earlyStreetAllIn else {
            return (nil, "当前有限模型仅覆盖双人河牌，或翻前／翻牌／转牌面对唯一已全下对手的完整跟注；其他可能有后续投入的场景不套用")
        }
        let legal = HandReducer.legalActions(in: snapshot, hand: hand)
        guard opponentPaid > paid else { return (nil, "当前没有待匹配的对手下注") }
        let cost = opponentPaid - paid
        // A short all-in call is not a full match. Do not use the full displayed pot
        // when any excess must be returned or when different pot rights would arise.
        guard legal.actorID == subjectID, legal.canCall, legal.callTo == opponentPaid,
              cost <= remaining,
              let price = PokerMath.callPrice(potBeforeCall: Double(pot), callCost: Double(cost), singleContestablePot: true,
                                              noFurtherInvestment: true, noPlayersBehind: true) else {
            return (nil, "当前不能以完整跟注匹配对手下注；短码跟注或退回投入需按实际可争夺池另行计算")
        }
        let condition = earlyStreetAllIn ? "唯一对手已全下；此次完整跟注后无后续投入，权益包含未发公共牌" : "河牌此次完整跟注关闭最终行动"
        return (price, "相对弃牌；\(condition)。仅在所示手牌／范围成立时适用，不代表优于所有其他行动")
    }
}

private struct RangeCalculationIdentity: Encodable {
    let id: UUID
    let contextKey: String
    let factRevision: Int
    let revision: Int
    let weights: [Double?]
    let source: String
    let name: String
    let isActive: Bool
    let removedEventID: UUID?
    let parentDependency: RangePlanDependency?
    let catalogReference: RangeCatalogReference?
}
