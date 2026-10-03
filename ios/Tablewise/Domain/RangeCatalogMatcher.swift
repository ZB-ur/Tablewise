import Foundation

/// Explicit recording facts only. Format/payouts cannot be guessed from blinds or stack sizes.
struct RangeCatalogQuery {
    let hand: HandRecord
    let eventID: UUID
    let after: Bool
    let targetPlayerID: UUID
    let format: String?
    var payouts: [Double]? = nil
    let projection: HandProjection
    init(hand: HandRecord, eventID: UUID, after: Bool, targetPlayerID: UUID, format: String?, payouts: [Double]? = nil) {
        self.hand = hand; self.eventID = eventID; self.after = after; self.targetPlayerID = targetPlayerID
        self.format = format; self.payouts = payouts; self.projection = HandReducer.project(hand)
    }
    var snapshot: HandSnapshot? {
        guard let node = projection.nodes.first(where: { $0.id == eventID }) else { return nil }
        return after ? node.after : node.before
    }
    var path: [HandNode] {
        let nodes = projection.nodes
        guard let index = nodes.firstIndex(where: { $0.id == eventID }) else { return [] }
        return Array(nodes.prefix(index + (after ? 1 : 0)))
    }
    var missing: [String] {
        var values: [String] = []
        if format == nil { values.append("牌局赛制尚未明确（现金局／锦标赛）") }
        else if !["cash","tournament"].contains(format!) { values.append("赛制不受支持") }
        if format == "tournament" && payouts == nil { values.append("锦标赛奖金条件未提供；不能精确匹配") }
        if hand.ruleApplicabilityIssue != nil { values.append("当前附加规则不在支持范围") }
        if hand.configuration.bigBlind <= 0 { values.append("实际大盲无效") }
        if !hand.players.contains(where: { $0.id == targetPlayerID }) { values.append("范围玩家不在本手") }
        if hand.players.contains(where: { $0.startingStack.certainty != .exact || $0.startingStack.units == nil }) { values.append("各玩家精确起始筹码未齐") }
        guard let snapshot else { return values + ["原行动节点已不存在"] }
        if snapshot.blocked { values.append("节点或前序行动存在冲突") }
        if snapshot.hasUncertainty { values.append("当前底池／各玩家筹码不精确") }
        if hand.potNeedsReconciliation(nodeEventID: eventID, after: after) { values.append("底池记忆与推导差异待核对") }
        if path.contains(where: { [.deadBlind,.liveBlind].contains($0.event.kind) }) { values.append("补盲路径尚不在 v1 精确匹配契约中") }
        if case .button = hand.configuration.ante { values.append("按钮前注不在 v1 范围包契约中") }
        return values
    }
}

enum RangeCatalogMatcher {
    static func close(_ a: Double, _ b: Double) -> Bool { a.isFinite && b.isFinite && abs(a - b) <= 1e-9 }
    static func number(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 >= 0 } ?? false }
    static func contextMissing(_ context: RangeCatalogPack.Context) -> [String] {
        var missing: [String] = []
        let rules = context.rules
        if rules.variant != "NLHE" || !["cash","tournament"].contains(rules.format ?? "") { missing.append("赛制") }
        if rules.format == "tournament" && (rules.payouts == nil || rules.payouts!.isEmpty || !rules.payouts!.allSatisfy { $0.isFinite && $0 >= 0 }) { missing.append("奖金结构") }
        if !(2...9).contains(rules.playersDealt ?? 0) { missing.append("发牌人数") }
        if !number(rules.blinds.smallBb) || rules.blinds.smallBb == 0 || rules.blinds.bigBb != 1 { missing.append("实际大小盲") }
        if !["none","per_player","big_blind"].contains(rules.ante.mode ?? "") || !number(rules.ante.amountBb) || (rules.ante.mode == "none" && rules.ante.amountBb != 0) { missing.append("前注") }
        if rules.rake.percent != 0 || rules.rake.capBb != 0 || rules.rake.noFlopNoDrop == nil { missing.append("明确无抽水规则") }
        guard let seats = context.seats else { return missing + ["座位／位置／各自起始筹码"] }
        let ids = Set(seats.map(\.playerId))
        if seats.count != rules.playersDealt || ids.count != seats.count || Set(seats.map(\.seat)).count != seats.count ||
            Set(seats.compactMap(\.position)).count != seats.count || seats.contains(where: { $0.playerId.isEmpty || !(0...8).contains($0.seat) || $0.position?.isEmpty != false || !number($0.startingStackBb) }) { missing.append("完整独立座位与筹码") }
        if context.board == nil { missing.append("当前牌面") }
        if !number(context.potBb) { missing.append("当前底池") }
        if context.stackBbByPlayer.map({ Set($0.keys) == ids && $0.values.allSatisfy(number) }) != true { missing.append("各玩家当前后手") }
        if let path = context.actionPath {
            let streets = ["preflop":0,"flop":1,"turn":2,"river":3]
            var priorStreet = 0
            for action in path {
                guard let street = streets[action.street], street >= priorStreet, street <= (streets[context.street] ?? -1), ids.contains(action.playerId) else { missing.append("完整有序行动路径"); break }
                priorStreet = street
                if ["fold","check"].contains(action.kind) {
                    if action.amountBb != nil || action.amountMeaning != nil { missing.append("过牌／弃牌尺度") }
                } else if ["call","bet","raise","all_in","post_blind","post_ante"].contains(action.kind) {
                    if !number(action.amountBb) || !["to","cost","increment"].contains(action.amountMeaning ?? "") { missing.append("明确行动尺度") }
                } else { missing.append("行动类型") }
            }
        } else { missing.append("完整行动路径") }
        return Array(Set(missing)).sorted()
    }

    static func differences(_ context: RangeCatalogPack.Context, targetSourcePlayer: String, query: RangeCatalogQuery) -> [String] {
        guard query.missing.isEmpty, let snapshot = query.snapshot, let seats = context.seats,
              let sourcePath = context.actionPath, let board = context.board, let stacks = context.stackBbByPlayer else { return ["条件缺项"] }
        var differences = contextMissing(context)
        guard differences.isEmpty else { return differences }
        let hand = query.hand, rules = context.rules, bb = Double(hand.configuration.bigBlind)
        let positions = HandReducer.positions(in: hand)
        let byPosition = Dictionary(uniqueKeysWithValues: seats.compactMap { seat in seat.position.map { ($0, seat) } })
        if rules.format != query.format || rules.payouts != query.payouts { differences.append("赛制／奖金条件") }
        if rules.playersDealt != hand.players.count { differences.append("发牌人数") }
        if !close(rules.blinds.smallBb ?? -1, Double(hand.configuration.smallBlind) / bb) { differences.append("大小盲比例") }
        let ante: (String,Double)
        switch hand.configuration.ante {
        case .none: ante = ("none",0)
        case .perPlayer(let n): ante = ("per_player",Double(n)/bb)
        case .bigBlind(let n): ante = ("big_blind",Double(n)/bb)
        case .button: return differences + ["按钮前注不支持"]
        }
        if rules.ante.mode != ante.0 || !close(rules.ante.amountBb ?? -1, ante.1) { differences.append("前注条件") }
        // At zero rake no-flop-no-drop has no monetary effect; no rake is already mandatory.
        if context.street != snapshot.street.rawValue || board != snapshot.board.map(\.analysisIndex) { differences.append("街次／具体公共牌") }
        if !close(context.potBb ?? -1, Double(snapshot.pot.units ?? -1)/bb) { differences.append("当前底池") }
        var sourceIDByPlayer: [UUID:String] = [:]
        for player in hand.players {
            guard let position = positions[player.id], let source = byPosition[position] else { differences.append("玩家位置"); continue }
            sourceIDByPlayer[player.id] = source.playerId
            if !close(source.startingStackBb ?? -1, Double(player.startingStack.units ?? -1)/bb) { differences.append("各玩家起始筹码") }
            let sourceRemaining = stacks[source.playerId].flatMap { $0 } ?? -1
            if !close(sourceRemaining, Double(snapshot.player(player.id)?.remaining.units ?? -1)/bb) { differences.append("各玩家当前后手") }
        }
        if sourceIDByPlayer[query.targetPlayerID] != targetSourcePlayer { differences.append("范围玩家位置") }
        let sourceOrder = seats.sorted { $0.seat < $1.seat }
        if let button = sourceOrder.firstIndex(where: { $0.position == "BTN" || $0.position == "BTN/SB" }) {
            let ordered = Array(sourceOrder[button...]) + Array(sourceOrder[..<button])
            let actual = HandReducer.clockwise(hand.players, after: hand.configuration.buttonSeat, including: true).compactMap { positions[$0.id] }
            if ordered.compactMap(\.position) != actual { differences.append("座位行动顺序") }
        } else { differences.append("按钮位置") }
        let events = query.path.filter { $0.event.kind != .deal }
        if events.count != sourcePath.count { differences.append("完整行动路径长度") }
        else {
            for (node, reference) in zip(events, sourcePath) {
                if sourceIDByPlayer[node.event.playerID ?? UUID()] != reference.playerId || !actionMatches(reference, node: node, bigBlind: bb) { differences.append("行动路径／精确尺度"); break }
            }
        }
        return Array(Set(differences)).sorted()
    }

    static func actionMatches(_ action: RangeCatalogPack.Action, node: HandNode, bigBlind: Double) -> Bool {
        guard action.street == node.event.street.rawValue, action.kind == kind(node.event.kind) else { return false }
        if [.fold,.check].contains(node.event.kind) { return action.amountBb == nil && action.amountMeaning == nil }
        guard let amount = action.amountBb, node.event.amount?.certainty == .exact, let entered = node.event.amount?.units else { return false }
        let cost: Int64
        if node.event.kind.isForced { cost = entered }
        else {
            guard let id = node.event.playerID, let prior = node.before.player(id)?.streetContribution.units else { return false }
            cost = entered - prior
        }
        // increment/cost both mean chips paid on this event; raise size is never guessed.
        let actual = action.amountMeaning == "to" ? entered : cost
        return ["to","cost","increment"].contains(action.amountMeaning ?? "") && close(amount, Double(actual)/bigBlind)
    }
    static func kind(_ kind: HandEventKind) -> String? {
        switch kind {
        case .fold: "fold"; case .check: "check"; case .call: "call"; case .bet: "bet"; case .raiseTo: "raise"; case .allIn: "all_in"
        case .smallBlind,.bigBlind: "post_blind"; case .ante: "post_ante"
        case .deal,.deadBlind,.liveBlind: nil
        }
    }
    static func isImmediateLink(from: RangeCatalogPack.Node, before: RangeCatalogPack.Context, after: RangeCatalogPack.Context, actionID: String) -> Bool {
        guard let a = before.actionPath, let b = after.actionPath, b.count == a.count + 1,
              before.street == after.street, before.board == after.board,
              let action = from.actionDefinitions.first(where: { $0.id == actionID }), let last = b.last else { return false }
        for (x,y) in zip(a,b) {
            guard x.playerId == y.playerId && x.street == y.street && x.kind == y.kind && x.amountBb == y.amountBb && x.amountMeaning == y.amountMeaning else { return false }
        }
        return last.playerId == from.playerId && last.street == before.street && last.kind == action.kind && last.amountBb == action.amountBb && last.amountMeaning == action.amountMeaning
    }
}

extension RangeCatalogRepository {
    func match(_ query: RangeCatalogQuery) -> RangeCatalogMatchStatus {
        guard query.missing.isEmpty else { return .init(matches: [], missing: query.missing, mismatches: [], installationIssues: issues) }
        var matches: [RangeCatalogMatch] = [], mismatches: [String] = []
        for installed in installed {
            for id in installed.release.rangeNodeIds {
                guard let node = installed.pack.nodes.first(where: { $0.id == id }),
                      let context = installed.pack.contexts.first(where: { $0.id == node.contextId }),
                      let source = installed.pack.sources.first(where: { $0.id == node.sourceId }), let reach = node.reachRange else { continue }
                let different = RangeCatalogMatcher.differences(context, targetSourcePlayer: node.playerId, query: query)
                if different.isEmpty {
                    matches.append(.init(reference: .init(packageId: installed.pack.id, packageVersion: installed.pack.packageVersion, nodeId: node.id, contentHash: installed.release.sha256, reviewId: installed.release.reviewId),
                                         sourceName: source.name, sourceURI: source.uri, sourceRevision: source.revision ?? "", origin: node.quality.origin,
                                         conditions: "\(context.rules.playersDealt ?? 0) 人 · \(context.street) · 完整路径 \(context.actionPath?.count ?? 0) 步 · 无抽水", weights: reach.weights.map { $0.map { $0 * 100 } }))
                } else { mismatches += different }
            }
        }
        return .init(matches: matches, missing: [], mismatches: Array(Set(mismatches)).sorted(), installationIssues: issues)
    }
}
