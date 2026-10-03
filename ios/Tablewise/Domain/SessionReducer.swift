import Foundation

/// Replays hand results and independent boundary events without mutating prior hand snapshots.
enum SessionReducer {
    static func makeSession(title: String, configuration: HandConfiguration, players: [HandPlayer], gameFormat: HandGameFormat? = nil) throws -> SessionRecord {
        let hand = HandRecord(title: title, configuration: configuration, players: players)
        let issues = HandReducer.configurationIssues(hand)
        guard issues.isEmpty else { throw SessionError.invalid(issues.joined(separator: "；")) }
        var session = SessionRecord(title: title, initialConfiguration: configuration,
                                    players: players.map { .init(id: $0.id, name: $0.name, isHero: $0.isHero) },
                                    initialSeats: players.map { .init(playerID: $0.id, seat: $0.seat, balance: $0.startingStack) })
        session.gameFormat = gameFormat
        return session
    }

    static func previewNextHand(_ session: SessionRecord, hands: [HandRecord], buttonSeatOverride: Int? = nil,
                                allowIncompleteResult: Bool = false) -> SessionNextHandPreview {
        var configuration = session.initialConfiguration
        var identities = session.players
        var seats = session.initialSeats
        var issues: [String] = []
        if let issue = session.ruleApplicabilityIssue { issues.append(issue) }
        var finance: [SessionFinanceEntry] = []
        var lastButton: Int? = nil
        if !(5...9).contains(configuration.tableCapacity) { issues.append("桌容量必须为 5–9。") }
        if Set(identities.map(\.id)).count != identities.count { issues.append("场次身份重复。") }
        if Set(seats.map(\.playerID)).count != seats.count { issues.append("场次成员重复。") }
        if Set(session.hands.map(\.handID)).count != session.hands.count { issues.append("场次手牌引用重复。") }
        let activeEvents = session.events.filter { $0.cancelledAt == nil }
        for number in 1...session.nextHandNumber {
            for event in activeEvents where event.effectiveHandNumber == number {
                do { try apply(event, configuration: &configuration, identities: &identities, seats: &seats, finance: &finance) }
                catch { issues.append("第 \(number) 手变更：\(error.localizedDescription)") }
            }
            guard number <= session.hands.count else { break }
            guard let reference = session.hands.first(where: { $0.number == number }),
                  let hand = hands.first(where: { $0.id == reference.handID }) else {
                issues.append("第 \(number) 手记录缺失，不能推导后续余额。")
                for index in seats.indices { seats[index].balance = .unknown }
                continue
            }
            if let issue = hand.ruleApplicabilityIssue { issues.append("第 \(number) 手：" + issue) }
            issues += handMembershipIssues(hand, configuration: configuration, seats: seats).map { "第 \(number) 手：" + $0 }
            for player in hand.players {
                guard let expected = seats.first(where: { $0.playerID == player.id }) else {
                    issues.append("第 \(number) 手的玩家不在场次成员中。")
                    continue
                }
                if expected.balance.units != player.startingStack.units || expected.balance.certainty != player.startingStack.certainty {
                    issues.append("第 \(number) 手起始筹码与前手结算/资金事件不一致；需预览并更正后续余额，不能静默继承。")
                }
            }
            lastButton = hand.configuration.buttonSeat
            configuration.buttonSeat = hand.configuration.buttonSeat
            if let settlement = hand.settlement, settlement.isCurrent(for: hand) {
                for player in hand.players {
                    if let index = seats.firstIndex(where: { $0.playerID == player.id }) {
                        seats[index].balance = settlement.finalBalances.first(where: { $0.playerID == player.id })?.amount ?? .unknown
                    }
                }
            } else {
                for player in hand.players {
                    if let index = seats.firstIndex(where: { $0.playerID == player.id }) { seats[index].balance = .unknown }
                }
                if number == session.hands.count && !allowIncompleteResult {
                    issues.append("上一手尚无有效结算；请确认结算，或明确选择保留待核对余额继续。")
                }
            }
        }
        let occupied = seats.filter { $0.participation != .left }
        if Set(occupied.map(\.seat)).count != occupied.count || occupied.contains(where: { !(0..<configuration.tableCapacity).contains($0.seat) }) {
            issues.append("场次座位重复或超出桌容量。")
        }
        let participating = seats.filter { $0.participation == .playing }.sorted { $0.seat < $1.seat }
        if let override = buttonSeatOverride { configuration.buttonSeat = override }
        else if let previous = lastButton, let next = participating.first(where: { $0.seat > previous }) ?? participating.first {
            configuration.buttonSeat = next.seat
        }
        let players = participating.compactMap { seat -> HandPlayer? in
            guard let identity = identities.first(where: { $0.id == seat.playerID }) else { issues.append("座位身份不存在。"); return nil }
            return .init(id: identity.id, name: identity.name, seat: seat.seat, startingStack: seat.balance, isHero: identity.isHero)
        }
        let draft = HandRecord(title: "第 \(session.nextHandNumber) 手", configuration: configuration, players: players)
        issues += HandReducer.configurationIssues(draft)
        if players.contains(where: { $0.startingStack.units == 0 }) { issues.append("零筹码玩家请先补码或设为暂离，再开始下一手。") }
        if session.status == .ended { issues.append("场次已结束，请先恢复场次。") }
        return .init(number: session.nextHandNumber, configuration: configuration, identities: identities, seats: seats,
                     players: players, positions: HandReducer.positions(in: draft),
                     pendingEvents: activeEvents.filter { $0.effectiveHandNumber == session.nextHandNumber },
                     finance: finance, issues: issues, unconfirmedBalanceIDs: players.filter { $0.startingStack.certainty != .exact }.map(\.id))
    }

    static func startNextHand(_ session: inout SessionRecord, hands: [HandRecord], buttonSeatOverride: Int? = nil,
                              allowIncompleteResult: Bool = false) throws -> HandRecord {
        let preview = previewNextHand(session, hands: hands, buttonSeatOverride: buttonSeatOverride, allowIncompleteResult: allowIncompleteResult)
        guard preview.canStart else { throw SessionError.invalid(preview.issues.joined(separator: "；")) }
        var hand = HandReducer.makeHand(configuration: preview.configuration, players: preview.players, title: "\(session.title) · 第 \(preview.number) 手")
        hand.ruleContext = session.ruleContext
        hand.gameFormat = session.gameFormat
        session.hands.append(.init(handID: hand.id, number: preview.number))
        session.updatedAt = Date()
        return hand
    }

    /// Queue operations atomically. Joining/replacing an identity and its buy-in can be one batch.
    static func queue(_ kinds: [SessionEventKind], in session: inout SessionRecord, hands: [HandRecord], note: String = "") throws {
        guard session.status == .active else { throw SessionError.invalid("请先恢复场次。") }
        var candidate = session
        candidate.events += kinds.map { SessionEvent(effectiveHandNumber: session.nextHandNumber, kind: $0, note: note) }
        // Validate mutations separately from deal eligibility: fewer than two players may still be managed.
        let old = previewNextHand(session, hands: hands, allowIncompleteResult: true)
        var configuration = old.configuration
        var identities = old.identities
        var seats = old.seats
        var finance: [SessionFinanceEntry] = []
        for event in candidate.events.suffix(kinds.count) {
            try apply(event, configuration: &configuration, identities: &identities, seats: &seats, finance: &finance)
        }
        candidate.updatedAt = Date()
        session = candidate
    }
    static func cancel(eventID: UUID, in session: inout SessionRecord) throws {
        guard let index = session.events.firstIndex(where: { $0.id == eventID }), session.events[index].cancelledAt == nil else {
            throw SessionError.invalid("未找到待生效变更。")
        }
        guard session.events[index].effectiveHandNumber >= session.nextHandNumber else {
            throw SessionError.invalid("变更已生效，需通过历史更正预览处理，不能撤销历史事实。")
        }
        session.events[index].cancelledAt = Date()
        session.updatedAt = Date()
    }
    static func setEnded(_ ended: Bool, session: inout SessionRecord) {
        session.status = ended ? .ended : .active
        session.updatedAt = Date()
    }
    private static func handMembershipIssues(_ hand: HandRecord, configuration: HandConfiguration, seats: [SessionSeat]) -> [String] {
        let dealt = seats.filter { $0.participation == .playing }
        var issues: [String] = []
        if Set(dealt.map(\.playerID)) != Set(hand.players.map(\.id)) {
            issues.append("发牌名单与该手生效人员状态不一致。")
        }
        for player in hand.players {
            if seats.first(where: { $0.playerID == player.id })?.seat != player.seat {
                issues.append("玩家座位与该手生效座位不一致。")
            }
        }
        let saved = hand.configuration
        if saved.tableCapacity != configuration.tableCapacity || saved.smallBlind != configuration.smallBlind || saved.bigBlind != configuration.bigBlind || saved.ante != configuration.ante || saved.chipUnit != configuration.chipUnit {
            issues.append("手牌规则与该手生效场次规则不一致。")
        }
        // BTN is deliberately user-editable in the deal preview; snapshots own that choice.
        return issues
    }

    /// Validates persisted event replay independently of whether the next hand may start.
    /// Missing settlements and ended/fewer-than-two states are valid stored records.
    static func validateStoredSession(_ session: SessionRecord, hands: [HandRecord]) throws {
        let unsupportedRules = session.ruleApplicabilityIssue != nil || session.hands.contains { reference in
            hands.first(where: { $0.id == reference.handID })?.ruleApplicabilityIssue != nil
        }
        var configuration = session.initialConfiguration
        var identities = session.players
        var seats = session.initialSeats
        var finance: [SessionFinanceEntry] = []
        for event in session.events {
            guard (1...session.nextHandNumber).contains(event.effectiveHandNumber) else {
                throw SessionError.invalid("场次事件生效手数无效。")
            }
            // Even cancelled facts must have sane amounts; their historical applicability is not replayed.
            switch event.kind {
            case .buyIn(_, let amount), .topUp(_, let amount), .cashOut(_, let amount), .calibrate(_, let amount):
                guard amount.certainty == .exact, let units = amount.units, units >= 0 else {
                    throw SessionError.invalid("场次资金事件金额无效。")
                }
            case .rules(let small, let big, let ante):
                if let small, small <= 0 { throw SessionError.invalid("场次小盲无效。") }
                if let big, big <= 0 { throw SessionError.invalid("场次大盲无效。") }
                if let ante {
                    switch ante { case .none: break; case .perPlayer(let n), .bigBlind(let n), .button(let n):
                        guard n >= 0 else { throw SessionError.invalid("场次前注无效。") }
                    }
                }
            default: break
            }
        }
        for number in 1...session.nextHandNumber {
            for event in session.events where event.cancelledAt == nil && event.effectiveHandNumber == number {
                if unsupportedRules {
                    switch event.kind {
                    case .buyIn(let id, _), .topUp(let id, _), .cashOut(let id, _), .calibrate(let id, _):
                        guard seats.contains(where: { $0.playerID == id }) else { throw SessionError.invalid("资金事件玩家身份不存在。") }
                        continue
                    default: break
                    }
                }
                try apply(event, configuration: &configuration, identities: &identities, seats: &seats, finance: &finance)
            }
            guard number <= session.hands.count else { break }
            guard let reference = session.hands.first(where: { $0.number == number }),
                  let hand = hands.first(where: { $0.id == reference.handID }) else {
                throw SessionError.invalid("场次手牌引用或序号无效。")
            }
            let membershipIssues = handMembershipIssues(hand, configuration: configuration, seats: seats)
            guard membershipIssues.isEmpty else { throw SessionError.invalid("第 \(number) 手：" + membershipIssues.joined(separator: "；")) }
            for player in hand.players {
                guard let i = seats.firstIndex(where: { $0.playerID == player.id }) else {
                    throw SessionError.invalid("手牌包含场次中不存在的身份。")
                }
                // Unknown rules may change cross-hand payouts; validate identity/roster above,
                // but do not assert ordinary NLHE balance continuity for opaque stored contexts.
                if unsupportedRules { continue }
                let expected = seats[i].balance
                guard expected.units == player.startingStack.units, expected.certainty == player.startingStack.certainty else {
                    throw SessionError.invalid("第 \(number) 手起始筹码与前手结算及资金流水不一致。")
                }
                if let settlement = hand.settlement, settlement.isCurrent(for: hand) {
                    seats[i].balance = settlement.finalBalances.first(where: { $0.playerID == player.id })?.amount ?? .unknown
                } else { seats[i].balance = .unknown }
            }
        }
    }

    /// Called before any historic settlement edit is persisted. The pending calibration rule is not guessed.
    static func validateSettlementCorrection(handID: UUID, in session: SessionRecord) throws {
        guard let reference = session.hands.first(where: { $0.handID == handID }) else { throw SessionError.invalid("牌局不属于此场次。") }
        if session.events.contains(where: { event in
            guard event.cancelledAt == nil, event.effectiveHandNumber > reference.number else { return false }
            if case .calibrate = event.kind { return true }
            return false
        }) { throw SessionError.calibrationCorrectionRulePending }
    }

    static func apply(_ event: SessionEvent, configuration: inout HandConfiguration,
                              identities: inout [SessionPlayer], seats: inout [SessionSeat], finance: inout [SessionFinanceEntry]) throws {
        // Copy first: an invalid multi-field mutation never partially applies.
        var c = configuration; var people = identities; var roster = seats
        var entry: SessionFinanceEntry?
        func index(_ id: UUID) throws -> Int {
            guard let i = roster.firstIndex(where: { $0.playerID == id }) else { throw SessionError.invalid("玩家身份不存在。") }
            return i
        }
        func checkSeat(_ seat: Int, except id: UUID? = nil) throws {
            guard (0..<c.tableCapacity).contains(seat), !roster.contains(where: { $0.seat == seat && $0.participation != .left && $0.playerID != id }) else {
                throw SessionError.invalid("目标座位无效或已有人。")
            }
        }
        func checkAmount(_ amount: ChipAmount) throws {
            guard amount.certainty == .exact, let value = amount.units, value >= 0 else { throw SessionError.invalid("资金事件需要已确认且非负的金额。") }
        }
        switch event.kind {
        case .join(let player, let seat):
            guard !people.contains(where: { $0.id == player.id }) else { throw SessionError.invalid("新玩家必须使用独立身份。") }
            try checkSeat(seat)
            people.append(player); roster.append(.init(playerID: player.id, seat: seat, balance: .init(units: nil, source: "尚未买入")))
        case .leave(let id): roster[try index(id)].participation = .left
        case .sitOut(let id):
            let i = try index(id)
            guard roster[i].participation != .left else { throw SessionError.invalid("离桌玩家请先返回。") }
            roster[i].participation = .sittingOut
        case .returnToTable(let id, let participate):
            let i = try index(id); try checkSeat(roster[i].seat, except: id)
            roster[i].participation = participate ? .playing : .waiting
        case .moveSeat(let id, let seat):
            let i = try index(id); try checkSeat(seat, except: id); roster[i].seat = seat
        case .swapSeats(let first, let second):
            let a = try index(first), b = try index(second)
            guard roster[a].participation != .left, roster[b].participation != .left else { throw SessionError.invalid("换座双方必须仍在桌上。") }
            let seat = roster[a].seat; roster[a].seat = roster[b].seat; roster[b].seat = seat
        case .replaceIdentity(let old, let new):
            let i = try index(old)
            guard !people.contains(where: { $0.id == new.id }) else { throw SessionError.invalid("替换玩家必须使用全新身份。") }
            let seat = roster[i].seat; roster[i].participation = .left
            try checkSeat(seat)
            people.append(new); roster.append(.init(playerID: new.id, seat: seat, balance: .init(units: nil, source: "尚未买入")))
        case .buyIn(let id, let amount), .topUp(let id, let amount), .cashOut(let id, let amount), .calibrate(let id, let amount):
            try checkAmount(amount)
            let i = try index(id); let before = roster[i].balance
            let after: ChipAmount
            switch event.kind {
            case .calibrate: after = .init(units: amount.units, source: "实测校准")
            case .buyIn:
                guard before.units == 0 || (before.units == nil && before.source == "尚未买入") else { throw SessionError.invalid("已有筹码请使用补码；待核对余额请使用实测校准。") }
                after = .init(units: amount.units, source: "买入")
            case .cashOut: after = before.subtracting(amount)
            default: after = before.adding(amount)
            }
            if let value = after.units, value < 0 { throw SessionError.invalid("带走金额超过可用余额。") }
            if before.units != nil && after.units == nil { throw SessionError.invalid("金额超出可记录范围。") }
            roster[i].balance = after
            entry = .init(event: event, playerID: id, before: before, after: after)
        case .rules(let small, let big, let ante):
            if let small { guard small > 0 else { throw SessionError.invalid("小盲必须大于零。") }; c.smallBlind = small }
            if let big { guard big > 0 else { throw SessionError.invalid("大盲必须大于零。") }; c.bigBlind = big }
            if let ante {
                switch ante { case .none: break; case .perPlayer(let n), .bigBlind(let n), .button(let n):
                    guard n >= 0 else { throw SessionError.invalid("前注不能为负数。") }
                }
                c.ante = ante
            }
        }
        configuration = c; identities = people; seats = roster
        if let entry { finance.append(entry) }
    }

    /// Only the explicit continuous-session membership is sampled. Standalone history is never mixed in.
    static func statistics(_ session: SessionRecord, hands: [HandRecord], playerID: UUID) -> SessionPlayerStatistics {
        var result = SessionPlayerStatistics(playerID: playerID)
        if let issue = session.ruleApplicabilityIssue { result.exclusions.append(issue); return result }
        for reference in session.hands {
            guard let hand = hands.first(where: { $0.id == reference.handID }) else {
                result.exclusions.append("第 \(reference.number) 手记录缺失"); continue
            }
            guard let player = hand.players.first(where: { $0.id == playerID }) else { continue }
            result.dealtHands += 1
            let projection = HandReducer.project(hand)
            let preflop = projection.nodes.filter { $0.event.street == .preflop }
            var raises = 0
            var vpip = false, pfr = false, threeBet = false, opportunity = false
            var subjectFinished = false
            var threeBetEligibilityUnknown = false
            for node in preflop {
                // A later missing/conflicting action cannot erase already determinate personal facts.
                guard node.issues.isEmpty, !node.before.blocked else { break }
                if !node.event.kind.isForced && node.event.kind != .deal, let actor = node.event.playerID {
                    let contribution = node.after.player(actor)?.streetContribution.units
                    let before = node.before.player(actor)?.streetContribution.units
                    let increasesBet = contribution.map { $0 > node.before.currentBet } ?? false
                    if actor == playerID {
                        if let contribution, let before, contribution > before { vpip = true }
                        if increasesBet { pfr = true }
                        if raises == 1 {
                            let legal = HandReducer.legalActions(in: node.before, hand: hand)
                            if legal.canRaise {
                                // An unknown personal balance must not invent a re-raise opportunity.
                                if node.before.player(playerID)?.remaining.certainty == .exact || increasesBet {
                                    opportunity = true
                                    if increasesBet { threeBet = true }
                                } else { threeBetEligibilityUnknown = true }
                            }
                        }
                    }
                    if increasesBet { raises += 1 }
                }
                if let state = node.after.player(playerID), state.folded || state.allIn { subjectFinished = true }
                if node.after.roundComplete || node.after.handComplete { subjectFinished = true }
            }
            if vpip || subjectFinished {
                result.vpip.opportunities += 1
                if vpip { result.vpip.count += 1 }
            } else {
                result.vpip.excludedHands += 1
                result.exclusions.append("第 \(reference.number) 手 VPIP 尚不可判定")
            }
            if pfr || subjectFinished {
                result.pfr.opportunities += 1
                if pfr { result.pfr.count += 1 }
            } else {
                result.pfr.excludedHands += 1
                result.exclusions.append("第 \(reference.number) 手 PFR 尚不可判定")
            }
            if opportunity {
                result.threeBet.opportunities += 1
                if threeBet { result.threeBet.count += 1 }
            } else if threeBetEligibilityUnknown || (!subjectFinished && !pfr && raises < 2) {
                result.threeBet.excludedHands += 1
                result.exclusions.append("第 \(reference.number) 手 3-bet 机会尚不可判定")
            }
            if let settlement = hand.settlement, settlement.isCurrent(for: hand),
               let balance = settlement.finalBalances.first(where: { $0.playerID == playerID })?.amount,
               balance.certainty == .exact, player.startingStack.certainty == .exact,
               let net = balance.subtracting(player.startingStack).units, hand.configuration.bigBlind > 0 {
                result.settledHands += 1
                result.pokerNet = result.pokerNet.adding(.init(units: net))
                result.bigBlindNet += Double(net) / Double(hand.configuration.bigBlind)
            } else { result.unsettledHands += 1 }
        }
        return result
    }
}
