import Foundation

/// Replays immutable facts. Invalid historical facts remain addressable; dependent calculations stop.
enum HandReducer {
    static func orderedPlayers(_ hand: HandRecord) -> [HandPlayer] { hand.players.sorted { $0.seat < $1.seat } }
    static func positions(in hand: HandRecord) -> [UUID: String] {
        let order = clockwise(hand.players, after: hand.configuration.buttonSeat, including: true)
        guard order.count >= 2 else { return [:] }
        if order.count == 2 { return [order[0].id: "BTN/SB", order[1].id: "BB"] }
        var result = [order[0].id: "BTN", order[1].id: "SB", order[2].id: "BB"]
        let count = order.count - 3
        let labels: [String]
        switch count { case 0: labels = []; case 1: labels = ["CO"]; case 2: labels = ["UTG", "CO"]; case 3: labels = ["UTG", "HJ", "CO"]; case 4: labels = ["UTG", "LJ", "HJ", "CO"]; case 5: labels = ["UTG", "UTG+1", "LJ", "HJ", "CO"]; default: labels = ["UTG", "UTG+1", "UTG+2", "LJ", "HJ", "CO"] }
        for (index, player) in order.dropFirst(3).enumerated() { result[player.id] = index < labels.count ? labels[index] : "UTG+\(index)" }
        return result
    }
    static func clockwise(_ players: [HandPlayer], after seat: Int, including: Bool = false) -> [HandPlayer] {
        let sorted = players.sorted { $0.seat < $1.seat }
        return sorted.filter { including ? $0.seat >= seat : $0.seat > seat } + sorted.filter { including ? $0.seat < seat : $0.seat <= seat }
    }
    static func makeHand(configuration: HandConfiguration, players: [HandPlayer], title: String) -> HandRecord {
        var hand = HandRecord(title: title, configuration: configuration, players: players)
        guard configurationIssues(hand).isEmpty else { return hand }
        let order = clockwise(players, after: configuration.buttonSeat, including: true)
        let small = order.count == 2 ? order[0] : order[1]
        let big = order.count == 2 ? order[1] : order[2]
        var balances = Dictionary(uniqueKeysWithValues: players.map { ($0.id, $0.startingStack) })
        func post(_ player: HandPlayer, _ kind: HandEventKind, _ requested: Int64) {
            guard requested > 0 else { return }
            let balance = balances[player.id] ?? .unknown
            let paid = balance.units.map { min($0, requested) } ?? requested
            let amount = ChipAmount(units: paid, certainty: balance.certainty == .approximate ? .approximate : .exact, source: "规则自动投入")
            hand.events.append(.init(street: .preflop, playerID: player.id, kind: kind, amount: amount, source: "规则自动投入"))
            balances[player.id] = balance.subtracting(amount)
        }
        // Blind first: a short big blind covers the blind before the big-blind ante.
        post(small, .smallBlind, configuration.smallBlind)
        post(big, .bigBlind, configuration.bigBlind)
        switch configuration.ante {
        case .none: break
        case .perPlayer(let amount): for player in order { post(player, .ante, amount) }
        case .bigBlind(let amount): post(big, .ante, amount)
        case .button(let amount): post(order[0], .ante, amount)
        }
        return hand
    }
    /// Structural errors are distinct from legal-action conflicts; draft conflicts can be saved.
    static func configurationIssues(_ hand: HandRecord) -> [String] {
        var issues: [String] = []
        let c = hand.configuration
        if !(5...9).contains(c.tableCapacity) { issues.append("桌容量必须为 5–9") }
        if hand.players.count < 2 || hand.players.count > c.tableCapacity { issues.append("本手发牌人数必须为 2 至桌容量") }
        if Set(hand.players.map(\.id)).count != hand.players.count { issues.append("玩家身份重复") }
        if Set(hand.players.map(\.seat)).count != hand.players.count { issues.append("座位重复") }
        if hand.players.contains(where: { $0.seat < 0 || $0.seat >= c.tableCapacity }) { issues.append("座位超出桌容量（从 0 开始）") }
        if !hand.players.contains(where: { $0.seat == c.buttonSeat }) { issues.append("按钮必须指向本手玩家") }
        if c.smallBlind <= 0 || c.bigBlind <= 0 { issues.append("小盲与大盲必须分别大于零") }
        if c.chipUnit.value == nil { issues.append("最小筹码单位无效") }
        switch c.ante { case .none: break; case .perPlayer(let n), .bigBlind(let n), .button(let n): if n < 0 { issues.append("前注不能为负数") } }
        if hand.players.contains(where: { ($0.startingStack.units ?? 0) < 0 }) { issues.append("起始筹码不能为负数") }
        if Set(hand.events.map(\.id)).count != hand.events.count { issues.append("事件身份重复") }
        if hand.events.contains(where: { ($0.amount?.units ?? 0) < 0 }) { issues.append("事件金额不能为负数") }
        if hand.events.contains(where: { event in event.playerID.map { id in !hand.players.contains(where: { $0.id == id }) } ?? false }) { issues.append("事件玩家不存在") }
        let holeCards = hand.players.flatMap(\.holeCards)
        let cards = holeCards + hand.events.flatMap(\.cards)
        if hand.players.contains(where: { $0.holeCards.count > 2 }) { issues.append("玩家底牌最多两张") }
        if cards.contains(where: { !$0.isValid }) { issues.append("牌张无效") }
        if Set(holeCards).count != holeCards.count { issues.append("存在重复牌张") }
        return issues
    }
    static func project(_ hand: HandRecord) -> HandProjection {
        let configProblems = configurationIssues(hand).map { HandIssue(eventID: nil, message: $0) }
        var state = HandSnapshot(players: orderedPlayers(hand).map { PlayerSnapshot(id: $0.id, remaining: $0.startingStack, allIn: $0.startingStack.units == 0) }, lastFullRaise: hand.configuration.bigBlind)
        state.currentBet = hand.configuration.bigBlind
        state.blocked = !configProblems.isEmpty || hand.ruleApplicabilityIssue != nil
        refresh(&state, hand: hand, after: preflopPredecessor(hand))
        let initial = state
        var nodes: [HandNode] = []
        var issues = configProblems
        if let issue = hand.ruleApplicabilityIssue { issues.append(.init(eventID: hand.id, message: issue)) }
        // Reconstruct only the expected obligations, never insert missing facts into the saved history.
        let expected = configProblems.isEmpty ? makeHand(configuration: hand.configuration, players: hand.players, title: hand.title).events : []
        var forcedIndex = 0
        for event in hand.events {
            let predecessor = state
            var messages: [String] = []
            if state.blocked {
                messages = ["前序存在缺项或冲突；本事件保留待核对"]
            } else if forcedIndex < expected.count {
                let obligation = expected[forcedIndex]
                if event.kind != obligation.kind || event.playerID != obligation.playerID || event.street != .preflop {
                    messages = ["缺少或顺序错误的强制投入：\(obligation.kind.title)；后续事件保留待修正"]
                } else if event.amount?.units != obligation.amount?.units || event.amount?.certainty != obligation.amount?.certainty {
                    messages = ["强制投入金额与本手规则或可用筹码不符：\(obligation.kind.title)"]
                } else {
                    messages = apply(event, state: &state, hand: hand)
                    if messages.isEmpty {
                        forcedIndex += 1
                        state.forcedContributionsComplete = forcedIndex == expected.count
                    }
                }
            } else if [.smallBlind, .bigBlind, .ante].contains(event.kind) {
                messages = ["重复或不属于本手配置的强制投入"]
            } else {
                messages = apply(event, state: &state, hand: hand)
            }
            if !messages.isEmpty { state = predecessor; state.blocked = true }
            if event.kind == .deal {
                let observedIssues = observeDeal(event, state: &state, hand: hand)
                if !observedIssues.isEmpty { state.blocked = true }
                messages = observedIssues + messages
            }
            let nodeIssues = messages.map { HandIssue(eventID: event.id, message: $0) }
            issues.append(contentsOf: nodeIssues)
            nodes.append(.init(event: event,
                               before: scopedNodeSnapshot(predecessor, event: event, after: false),
                               after: scopedNodeSnapshot(state, event: event, after: true),
                               issues: nodeIssues))
        }
        if !state.blocked && forcedIndex < expected.count {
            state.blocked = true
            issues.append(.init(eventID: hand.id, message: "缺少强制投入：\(expected[forcedIndex].kind.title)；记录保留为不完整草稿"))
        }
        // The hand overview shows every known street even in an old entry-order draft.
        var latest = state
        latest.knownStreet = latest.knownBoard.keys.max { $0.order < $1.order }
        return .init(initial: initial, nodes: nodes, latest: latest, issues: issues)
    }
    /// Scope every node to its own street. The replay state retains all facts for conflict checks.
    private static func scopedNodeSnapshot(_ source: HandSnapshot, event: HandEvent, after: Bool) -> HandSnapshot {
        var snapshot = source
        let limit = event.street.order - (event.kind == .deal && !after ? 1 : 0)
        snapshot.knownStreet = snapshot.knownBoard.keys.filter { $0.order <= limit }
            .max { $0.order < $1.order } ?? .preflop
        let allowedCards = limit <= 0 ? 0 : limit == 1 ? 3 : limit == 2 ? 4 : 5
        if snapshot.board.count > allowedCards || snapshot.street.order > limit {
            // An old out-of-order fact cannot use a later legal board for node analysis.
            snapshot.board = Array(snapshot.board.prefix(allowedCards))
            snapshot.blocked = true
        }
        return snapshot
    }
    private static func observeDeal(_ event: HandEvent, state: inout HandSnapshot, hand: HandRecord) -> [String] {
        guard event.street != .preflop, event.cards.count == event.street.cardCount, event.cards.allSatisfy(\.isValid),
              Set(event.cards).count == event.cards.count else { return ["本街公共牌数量或牌张无效；已知牌未用于回放"] }
        guard state.knownBoard[event.street] == nil else { return ["同街重复公共牌；后录牌张保留待核对"] }
        let other = state.knownBoard.filter { $0.key != event.street }.values.flatMap { $0 }
        guard !event.cards.contains(where: { other.contains($0) || hand.players.flatMap(\.holeCards).contains($0) }) else {
            return ["公共牌重复；已知牌未用于回放"]
        }
        let outOfOrder = state.knownBoard.keys.contains { $0.order > event.street.order }
        state.knownBoard[event.street] = event.cards
        state.knownStreet = event.street
        var issues: [String] = []
        if outOfOrder { issues.append("公共牌事件顺序与街次不符；请在此节点按街次重插") }
        let missing = HandStreet.allCases.filter { $0.order > 0 && $0.order < event.street.order && state.knownBoard[$0]?.count != $0.cardCount }
        if !missing.isEmpty { issues.append("缺少前序公共牌：\(missing.map(\.title).joined(separator: "、"))；已知\(event.street.title)保留，牌力与计算暂停") }
        return issues
    }
    static func legalActions(in state: HandSnapshot, hand: HandRecord) -> LegalActions {
        guard !state.blocked, state.forcedContributionsComplete, !state.roundComplete, !state.handComplete, let id = state.actorID, let player = state.player(id), !player.folded, !player.allIn,
              let paid = player.streetContribution.units else { return .init() }
        let maximum = player.remaining.units.flatMap { remaining -> Int64? in let (v, overflow) = paid.addingReportingOverflow(remaining); return overflow ? nil : v }
        let reopen = player.lastActedAt.map { $0 == 0 || state.currentBet - $0 >= state.lastFullRaise } ?? true
        let canContest = state.players.contains { $0.id != id && !$0.folded && !$0.allIn }
        let callTarget = canContest ? state.currentBet : min(state.currentBet, state.players.filter { $0.id != id && !$0.folded }.compactMap { $0.streetContribution.units }.max() ?? 0)
        let (raiseSum, raiseOverflow) = state.currentBet.addingReportingOverflow(state.lastFullRaise)
        let minRaise = state.currentBet < hand.configuration.bigBlind ? hand.configuration.bigBlind : (raiseOverflow ? Int64.max : raiseSum)
        let canRaise = reopen && canContest && (maximum.map { $0 > state.currentBet } ?? true)
        return .init(actorID: id, canCheck: paid >= callTarget, canFold: true, canCall: paid < callTarget,
                     canRaise: canRaise, canAllIn: maximum.map { $0 <= callTarget || canRaise } ?? false,
                     callTo: maximum.map { min(callTarget, $0) } ?? callTarget,
                     minimumRaiseTo: minRaise, maximumTo: maximum)
    }
    static func validate(_ event: HandEvent, in hand: HandRecord) -> [String] {
        var candidate = hand
        candidate.events.append(event)
        let projection = project(candidate)
        let direct = projection.issues.filter { $0.eventID == nil || $0.eventID == event.id }.map(\.message)
        return direct
    }
    private static func preflopPredecessor(_ hand: HandRecord) -> UUID? {
        let order = clockwise(hand.players, after: hand.configuration.buttonSeat, including: true)
        guard order.count >= 2 else { return nil }
        return order[order.count == 2 ? 1 : 2].id
    }
    private static func refresh(_ state: inout HandSnapshot, hand: HandRecord, after id: UUID?) {
        let eligible = state.players.filter { !$0.folded }
        state.handComplete = eligible.count <= 1
        let active = eligible.filter { !$0.allIn }
        let need = active.filter { player in
            let target = active.count <= 1 ? min(state.currentBet, eligible.filter { $0.id != player.id }.compactMap { $0.streetContribution.units }.max() ?? 0) : state.currentBet
            return (player.streetContribution.units ?? 0) < target || (active.count > 1 && player.lastActedAt == nil)
        }
        state.roundComplete = state.handComplete || need.isEmpty
        if state.roundComplete { state.actorID = nil; return }
        let seat = hand.players.first { $0.id == id }?.seat ?? hand.configuration.buttonSeat
        state.actorID = clockwise(hand.players, after: seat).first { p in need.contains { $0.id == p.id } }?.id
    }
    private static func apply(_ event: HandEvent, state: inout HandSnapshot, hand: HandRecord) -> [String] {
        if event.kind == .deal {
            guard !state.handComplete else { return ["牌局已由弃牌结束"] }
            guard state.roundComplete else { return ["本街行动尚未结束；跨街记录保留为缺项"] }
            guard state.street.next == event.street else { return ["公共牌街次不连续，缺少前序街次"] }
            guard event.cards.count == event.street.cardCount else { return ["本街公共牌数量不正确"] }
            let used = state.board + hand.players.flatMap(\.holeCards)
            guard event.cards.allSatisfy(\.isValid), Set(event.cards).count == event.cards.count, !event.cards.contains(where: { used.contains($0) }) else { return ["公共牌重复或无效"] }
            state.street = event.street; state.board += event.cards; state.currentBet = 0; state.lastFullRaise = hand.configuration.bigBlind
            for i in state.players.indices { state.players[i].streetContribution = .zero; state.players[i].lastActedAt = nil }
            let button = hand.players.first { $0.seat == hand.configuration.buttonSeat }?.id
            refresh(&state, hand: hand, after: button)
            return []
        }
        guard event.street == state.street else { return ["行动街次与当前街次不一致"] }
        guard let id = event.playerID, let index = state.players.firstIndex(where: { $0.id == id }) else { return ["缺少有效行动玩家"] }
        if event.kind.isForced {
            let supplemental = event.kind == .liveBlind || event.kind == .deadBlind
            guard state.street == .preflop else { return ["补盲与强制投入只能记录在翻前"] }
            if supplemental {
                guard state.forcedContributionsComplete, !state.handComplete, !state.roundComplete,
                      !state.players[index].folded, !state.players[index].allIn, state.players[index].lastActedAt == nil else {
                    return ["补盲须在常规盲注完成后、该玩家首次自愿行动前录入"]
                }
            } else if !state.players.allSatisfy({ $0.lastActedAt == nil }) {
                return ["常规强制投入必须在翻前自愿行动之前"]
            }
            guard let amount = event.amount, let units = amount.units, units >= 0 else { return ["强制投入金额未知或无效"] }
            if supplemental && units == 0 { return ["实际补盲金额必须大于零"] }
            if let remaining = state.players[index].remaining.units, units > remaining { return ["强制投入超出剩余筹码"] }
            if let pot = state.pot.units, pot.addingReportingOverflow(units).overflow { return ["累计底池超出整数表示范围"] }
            let previousActor = state.actorID
            pay(amount, index: index, live: event.kind == .smallBlind || event.kind == .bigBlind || event.kind == .liveBlind, state: &state)
            // A recorded live credit is not a straddle and cannot increase the required betting level.
            if !supplemental { state.currentBet = max(state.currentBet, state.players[index].streetContribution.units ?? 0) }
            refresh(&state, hand: hand, after: supplemental ? previousActor : preflopPredecessor(hand))
            if supplemental, !state.roundComplete, let previousActor, let player = state.player(previousActor),
               !player.folded, !player.allIn,
               player.lastActedAt == nil || (player.streetContribution.units ?? 0) < state.currentBet {
                state.actorID = previousActor
            }
            return []
        }
        guard !state.handComplete, !state.roundComplete else { return ["本街已结束，不能继续行动"] }
        guard state.actorID == id else { return ["行动顺序不正确"] }
        guard !state.players[index].folded, !state.players[index].allIn else { return ["弃牌或全下玩家不能继续行动"] }
        let legal = legalActions(in: state, hand: hand)
        let paid = state.players[index].streetContribution.units ?? 0
        switch event.kind {
        case .fold: state.players[index].folded = true
        case .check:
            guard legal.canCheck else { return ["面对下注不能过牌"] }
        case .call, .bet, .raiseTo, .allIn:
            guard let amount = event.amount, let target = amount.units else { return ["金额未知；保留记录并暂停依赖计算"] }
            guard target >= paid else { return ["目标总额小于已投入"] }
            if let maximum = legal.maximumTo, target > maximum { return ["本次投入超出剩余筹码"] }
            let isAllIn = legal.maximumTo == target
            if event.kind == .call {
                guard legal.canCall, target == legal.callTo else { return ["跟注金额与当前需跟到总额不符"] }
            } else if event.kind == .allIn {
                guard legal.canAllIn, isAllIn else { return ["全下必须使用已知全部剩余筹码，且符合重开规则"] }
            } else {
                if event.kind == .bet && state.currentBet != 0 { return ["已有下注，请使用加注到"] }
                if event.kind == .raiseTo && state.currentBet == 0 { return ["无人下注，请使用下注"] }
                guard legal.canRaise, target > state.currentBet else { return ["下注未重开或加注总额不足"] }
            }
            if target > state.currentBet {
                guard legal.canRaise else { return ["短全下尚未重开下注"] }
                guard target >= legal.minimumRaiseTo || isAllIn else { return ["低于最小加注到 \(hand.configuration.chipUnit.format(units: legal.minimumRaiseTo))"] }
                let increment = target - state.currentBet
                if target >= legal.minimumRaiseTo { state.lastFullRaise = state.currentBet < hand.configuration.bigBlind ? target : increment }
                state.currentBet = target
            }
            if let pot = state.pot.units, pot.addingReportingOverflow(target - paid).overflow { return ["累计底池超出整数表示范围"] }
            let contribution = ChipAmount(units: target - paid, certainty: amount.certainty, source: amount.source)
            pay(contribution, index: index, live: true, state: &state)
        default: return ["不支持的行动"]
        }
        state.players[index].lastActedAt = state.currentBet
        refresh(&state, hand: hand, after: id)
        return []
    }
    private static func pay(_ amount: ChipAmount, index: Int, live: Bool, state: inout HandSnapshot) {
        state.players[index].remaining = state.players[index].remaining.subtracting(amount)
        state.players[index].totalContribution = state.players[index].totalContribution.adding(amount)
        if live { state.players[index].streetContribution = state.players[index].streetContribution.adding(amount) }
        state.players[index].allIn = state.players[index].remaining.units == 0
        state.pot = state.pot.adding(amount)
    }
}
