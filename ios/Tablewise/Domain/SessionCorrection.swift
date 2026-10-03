import Foundation

enum SessionCorrectionRequest: Sendable {
    case settlement(handID: UUID, selections: [Int: SettlementSelection])
    case event(eventID: UUID, replacement: SessionEventKind, effectiveHandNumber: Int, resolutions: [SessionHandFactResolution] = [], relatedEffectiveHandNumbers: [UUID: Int] = [:])
    case hand(replacement: HandRecord)
}
/// Every original player's cards and every original event require an explicit human disposition.
struct SessionHandFactResolution: Sendable {
    let hand: HandRecord
    let reviewedPlayerIDs: Set<UUID>
    let reviewedEventIDs: Set<UUID>
    /// nil deliberately retains an unconfirmed result; an empty dictionary requests automatic evaluation.
    let settlementSelections: [Int: SettlementSelection]?
}
struct SessionHandRepairRequirement: Sendable, Identifiable {
    let original: HandRecord
    let number: Int
    let configuration: HandConfiguration
    let players: [HandPlayer]
    let reasons: [String]
    var id: UUID { original.id }
}
struct SessionCorrectionArchive: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var reason: String
    var previousEvents: [SessionEvent]
    var previousHands: [HandRecord]
    var previousInitialConfiguration: HandConfiguration
    var previousInitialSeats: [SessionSeat]
}
struct SessionCorrectionBaseline: Sendable {
    let data: Data
}
struct SessionCorrectionPlayerImpact: Sendable, Identifiable {
    let playerID: UUID
    let previouslyDealt: Bool
    let proposedDealt: Bool
    let previousSeat: Int
    let proposedSeat: Int
    let previousStart: ChipAmount
    let proposedStart: ChipAmount
    let previousEnd: ChipAmount
    let proposedEnd: ChipAmount
    var id: UUID { playerID }
}
struct SessionCorrectionImpact: Sendable, Identifiable {
    let handID: UUID
    let number: Int
    let previousConfiguration: HandConfiguration
    let proposedConfiguration: HandConfiguration
    let previousGameFormat: HandGameFormat?
    let proposedGameFormat: HandGameFormat?
    let players: [SessionCorrectionPlayerImpact]
    let settlementReplayed: Bool
    let issues: [String]
    var id: UUID { handID }
}
struct SessionCorrectionEventImpact: Sendable, Identifiable {
    let previous: SessionEvent
    let proposed: SessionEvent
    var id: UUID { previous.id }
}
struct SessionCorrectionPreview: Sendable {
    let request: SessionCorrectionRequest
    let sessionID: UUID
    let baseline: SessionCorrectionBaseline
    let session: SessionRecord
    /// Only changed records. The store must commit these and session together.
    let hands: [HandRecord]
    let impacts: [SessionCorrectionImpact]
    let eventImpacts: [SessionCorrectionEventImpact]
    let conflicts: [String]
    let requiredRepairs: [SessionHandRepairRequirement]
    let revisionHighWatermarks: [UUID: Int]
    var canCommit: Bool { requiredRepairs.isEmpty && conflicts.isEmpty && (!hands.isEmpty || session.corrections?.last != nil) }
}

extension SessionReducer {
    /// Candidates only: each companion needs an explicit requested boundary. Never infer a move.
    static func relatedBoundaryEvents(to event: SessionEvent, in session: SessionRecord) -> [SessionEvent] {
        func introducedID(_ kind: SessionEventKind) -> UUID? {
            switch kind {
            case .join(let player, _), .replaceIdentity(_, let player): return player.id
            default: return nil
            }
        }
        return session.events.filter { other in
            guard other.id != event.id, other.cancelledAt == nil,
                  other.effectiveHandNumber == event.effectiveHandNumber else { return false }
            if let id = introducedID(event.kind), case .buyIn(let actor, _) = other.kind { return id == actor }
            if case .buyIn(let actor, _) = event.kind { return introducedID(other.kind) == actor }
            return false
        }
    }

    private struct CorrectionInput: Encodable {
        let session: SessionRecord
        let hands: [HandRecord]
    }
    private static func correctionBaseline(_ session: SessionRecord, hands: [HandRecord]) throws -> SessionCorrectionBaseline {
        let linked = try session.hands.map { reference -> HandRecord in
            guard let hand = hands.first(where: { $0.id == reference.handID }) else { throw SessionError.invalid("场次手牌缺失。") }
            return hand
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return .init(data: try encoder.encode(CorrectionInput(session: session, hands: linked)))
    }
    static func correctionIsCurrent(_ preview: SessionCorrectionPreview, session: SessionRecord, hands: [HandRecord]) throws -> Bool {
        guard preview.sessionID == session.id else { return false }
        let current = try correctionBaseline(session, hands: hands)
        return preview.baseline.data == current.data
    }

    /// Builds a detached transaction. No original hand, event, or settlement is changed during preview.
    static func previewCorrection(_ originalSession: SessionRecord, hands allHands: [HandRecord], request: SessionCorrectionRequest,
                                  revisionHighWatermarks: [UUID: Int] = [:]) -> SessionCorrectionPreview {
        var candidate = originalSession
        var replacements: [HandRecord] = []
        var impacts: [SessionCorrectionImpact] = []
        var eventImpacts: [SessionCorrectionEventImpact] = []
        var conflicts: [String] = []
        var requiredRepairs: [SessionHandRepairRequirement] = []
        var baseline = SessionCorrectionBaseline(data: Data())
        var reason = "历史更正"
        do {
            baseline = try correctionBaseline(originalSession, hands: allHands)
            try validateStoredSession(originalSession, hands: allHands)
            func prepared(_ hand: HandRecord) -> HandRecord {
                var result = hand
                let versions = allHands.filter { $0.id == hand.id }
                    + (originalSession.corrections ?? []).flatMap(\.previousHands).filter { $0.id == hand.id }
                result.retainRevisionCeiling(max(revisionHighWatermarks[hand.id] ?? 0,
                                                 versions.map(\.allocatedRevisionCeiling).max() ?? hand.revision))
                return result
            }
            var firstNumber: Int
            var sourceHandID: UUID?
            var sourceReplacement: HandRecord?
            var allowDraftConflicts = false
            var manualResolutions: [SessionHandFactResolution] = []
            switch request {
            case .settlement(let handID, let selections):
                guard let ref = candidate.hands.first(where: { $0.handID == handID }),
                      let hand = allHands.first(where: { $0.id == handID }) else { throw SessionError.invalid("待更正手牌不属于此场次。") }
                try validateSettlementCorrection(handID: handID, in: candidate)
                sourceReplacement = try HandSettlement.confirm(prepared(hand), selections: selections, correction: true)
                sourceHandID = handID; firstNumber = ref.number; reason = "第 \(ref.number) 手结算更正"
            case .event(let eventID, let replacement, let number, let resolutions, let relatedNumbers):
                guard let index = candidate.events.firstIndex(where: { $0.id == eventID }),
                      candidate.events[index].cancelledAt == nil,
                      candidate.events[index].effectiveHandNumber <= candidate.hands.count,
                      (1...candidate.nextHandNumber).contains(number) else { throw SessionError.invalid("请选择已生效事件及有效的更正手数。") }
                guard Set(resolutions.map { $0.hand.id }).count == resolutions.count,
                      resolutions.allSatisfy({ resolution in candidate.hands.contains { $0.handID == resolution.hand.id } }) else {
                    throw SessionError.invalid("逐手修正重复或不属于本场次。")
                }
                let originalEvent = candidate.events[index]
                let related = relatedBoundaryEvents(to: originalEvent, in: originalSession)
                guard Set(relatedNumbers.keys).isSubset(of: Set(related.map(\.id))),
                      relatedNumbers.values.allSatisfy({ (1...candidate.nextHandNumber).contains($0) }) else {
                    throw SessionError.invalid("关联更正只能选择此边界同一身份的加入／替换与买入，并填写有效的生效手数。")
                }
                manualResolutions = resolutions
                firstNumber = min(number, originalEvent.effectiveHandNumber)
                candidate.events[index].kind = replacement
                candidate.events[index].effectiveHandNumber = number
                eventImpacts.append(.init(previous: originalEvent, proposed: candidate.events[index]))
                // Keep original event order, actors and amounts. Only explicitly selected boundaries change.
                for relatedEvent in related {
                    guard let newNumber = relatedNumbers[relatedEvent.id],
                          let relatedIndex = candidate.events.firstIndex(where: { $0.id == relatedEvent.id }) else { continue }
                    firstNumber = min(firstNumber, min(relatedEvent.effectiveHandNumber, newNumber))
                    candidate.events[relatedIndex].effectiveHandNumber = newNumber
                    eventImpacts.append(.init(previous: relatedEvent, proposed: candidate.events[relatedIndex]))
                }
                reason = "人员或资金事件历史更正"
            case .hand(let replacement):
                guard let ref = candidate.hands.first(where: { $0.handID == replacement.id }),
                      let old = allHands.first(where: { $0.id == replacement.id }) else { throw SessionError.invalid("待更正手牌不属于此场次。") }
                guard Set(old.players.map(\.id)) == Set(replacement.players.map(\.id)) else {
                    throw SessionError.invalid("不能自动替换发牌身份；请明确修正人员来源和对应手牌。")
                }
                firstNumber = ref.number; sourceHandID = replacement.id; allowDraftConflicts = true
                var changed = prepared(replacement)
                // The caller's draft cannot manufacture a current settlement or discard its history.
                changed.revision = old.revision
                changed.retainRevisionCeiling(prepared(old).allocatedRevisionCeiling)
                changed.settlement = old.settlement
                changed.settlementHistory = old.settlementHistory
                changed.touch()
                sourceReplacement = changed
                reason = "第 \(ref.number) 手事实更正"
                if replacement.configuration != old.configuration {
                    guard replacement.configuration.tableCapacity == old.configuration.tableCapacity,
                          replacement.configuration.chipUnit == old.configuration.chipUnit else {
                        throw SessionError.invalid("连续场次已发牌后的桌容量和最小筹码单位不能由单手更正改写。")
                    }
                    // A recorded correction, at the original boundary, is distinct from a routine next-hand change.
                    if replacement.configuration.smallBlind != old.configuration.smallBlind || replacement.configuration.bigBlind != old.configuration.bigBlind || replacement.configuration.ante != old.configuration.ante {
                        candidate.events.append(.init(effectiveHandNumber: ref.number, kind: .rules(smallBlind: replacement.configuration.smallBlind, bigBlind: replacement.configuration.bigBlind, ante: replacement.configuration.ante), note: "历史手牌规则更正"))
                    }
                }
                if ref.number == 1 {
                    for player in replacement.players {
                        guard let prior = old.players.first(where: { $0.id == player.id }),
                              prior.startingStack.units != player.startingStack.units || prior.startingStack.certainty != player.startingStack.certainty else { continue }
                        let hasBoundaryFunds = candidate.events.contains { event in
                            guard event.cancelledAt == nil, event.effectiveHandNumber == 1 else { return false }
                            switch event.kind {
                            case .buyIn(let id, _), .topUp(let id, _), .cashOut(let id, _), .calibrate(let id, _): return id == player.id
                            default: return false
                            }
                        }
                        guard !hasBoundaryFunds else {
                            throw SessionError.invalid("首手起始余额包含独立资金事件；请更正对应资金来源，不能覆盖原始入座余额。")
                        }
                        if let index = candidate.initialSeats.firstIndex(where: { $0.playerID == player.id }) {
                            candidate.initialSeats[index].balance = player.startingStack
                        }
                    }
                }
            }
            // Both the old and proposed chain are checked: deleting/moving an anchor must not evade the pending rule.
            let includesBoundary: Bool
            if case .event = request { includesBoundary = true } else { includesBoundary = false }
            if (originalSession.events + candidate.events).contains(where: { event in
                guard event.cancelledAt == nil,
                      (includesBoundary ? event.effectiveHandNumber >= firstNumber : event.effectiveHandNumber > firstNumber) else { return false }
                if case .calibrate = event.kind { return true }; return false
            }) { throw SessionError.calibrationCorrectionRulePending }

            var configuration = candidate.initialConfiguration
            var identities = candidate.players
            var seats = candidate.initialSeats
            var finance: [SessionFinanceEntry] = []
            for number in 1...candidate.nextHandNumber {
                for event in candidate.events where event.cancelledAt == nil && event.effectiveHandNumber == number {
                    try apply(event, configuration: &configuration, identities: &identities, seats: &seats, finance: &finance)
                }
                guard number <= candidate.hands.count else { break }
                guard let ref = candidate.hands.first(where: { $0.number == number }),
                      let old = allHands.first(where: { $0.id == ref.handID }) else { throw SessionError.invalid("场次手牌引用无效。") }
                var changed = old
                var handIssues: [String] = []
                var replayed = false
                if number >= firstNumber {
                    changed = prepared(changed)
                    if old.id == sourceHandID, let sourceReplacement { changed = sourceReplacement }
                    let playing = seats.filter { $0.participation == .playing }
                    let expectedPlayers: [HandPlayer] = playing.compactMap { seat in
                        guard let person = identities.first(where: { $0.id == seat.playerID }) else { return nil }
                        return .init(id: person.id, name: person.name, seat: seat.seat, startingStack: seat.balance,
                                     holeCards: old.players.first(where: { $0.id == person.id })?.holeCards ?? [], isHero: person.isHero)
                    }
                    func requireRepair(_ reasons: [String]) {
                        var expectedConfiguration = configuration
                        expectedConfiguration.buttonSeat = old.configuration.buttonSeat
                        requiredRepairs.append(.init(original: old, number: number, configuration: expectedConfiguration, players: expectedPlayers, reasons: reasons))
                        // A hand whose actual facts are not yet confirmed has no usable payout.
                        for i in seats.indices where playing.contains(where: { $0.playerID == seats[i].playerID }) {
                            seats[i].balance = .unknown
                        }
                    }
                    let resolution = manualResolutions.first { $0.hand.id == old.id }
                    if let resolution {
                        var resolutionIssues: [String] = []
                        let reviewPlayers = Set(old.players.map(\.id)).union(expectedPlayers.map(\.id))
                        if !reviewPlayers.isSubset(of: resolution.reviewedPlayerIDs) { resolutionIssues.append("请逐位核对参与名单及底牌归属。") }
                        if !Set(old.events.map(\.id)).isSubset(of: resolution.reviewedEventIDs) { resolutionIssues.append("请逐条确认原行动的保留、更正或移除。") }
                        if Set(resolution.hand.players.map(\.id)) != Set(expectedPlayers.map(\.id)) { resolutionIssues.append("修正名单与已更正的人员事件不一致。") }
                        for player in resolution.hand.players {
                            guard let expected = expectedPlayers.first(where: { $0.id == player.id }) else { continue }
                            if player.seat != expected.seat || player.startingStack.units != expected.startingStack.units || player.startingStack.certainty != expected.startingStack.certainty {
                                resolutionIssues.append("\(player.name) 的座位或起始金额已随前序修正改变，请重新核对。")
                            }
                        }
                        var resolutionConfiguration = resolution.hand.configuration
                        resolutionConfiguration.buttonSeat = configuration.buttonSeat
                        if resolutionConfiguration != configuration { resolutionIssues.append("本手规则必须与该边界的场次规则一致。") }
                        if !resolutionIssues.isEmpty { requireRepair(resolutionIssues); continue }
                        changed = prepared(resolution.hand)
                        changed.revision = old.revision
                        changed.retainRevisionCeiling(prepared(old).allocatedRevisionCeiling)
                        // Complete old records remain in the correction archive, including removed identities' payouts.
                        if Set(old.players.map(\.id)) == Set(changed.players.map(\.id)) {
                            changed.settlement = old.settlement; changed.settlementHistory = old.settlementHistory
                        } else { changed.settlement = nil; changed.settlementHistory = nil }
                        changed.touch()
                    } else if Set(playing.map(\.playerID)) != Set(changed.players.map(\.id)) {
                        requireRepair(["人员更正改变了本手发牌名单，请明确逐位底牌和每条行动的实际归属。"])
                        continue
                    }
                    let originalButtonID = old.players.first(where: { $0.seat == old.configuration.buttonSeat })?.id
                    var derivedChanged = false
                    for index in changed.players.indices {
                        guard let expected = playing.first(where: { $0.playerID == changed.players[index].id }) else { continue }
                        if case .hand = request, old.id == sourceHandID {
                            guard changed.players[index].seat == expected.seat else { throw SessionError.invalid("更正座位请使用人员事件更正，不能只改单手快照。") }
                            let proposed = changed.players[index].startingStack
                            if proposed.units != expected.balance.units || proposed.certainty != expected.balance.certainty {
                                throw SessionError.invalid("第 \(number) 手起始筹码与前手结算或资金流水不一致；请先更正金额来源。")
                            }
                        } else {
                            if changed.players[index].startingStack.units != expected.balance.units || changed.players[index].startingStack.certainty != expected.balance.certainty {
                                changed.players[index].startingStack = expected.balance; derivedChanged = true
                            }
                            if changed.players[index].seat != expected.seat {
                                changed.players[index].seat = expected.seat; derivedChanged = true
                            }
                        }
                    }
                    var correctedConfiguration = configuration
                    correctedConfiguration.buttonSeat = changed.configuration.buttonSeat
                    if case .event = request, resolution == nil, let originalButtonID,
                       let button = changed.players.first(where: { $0.id == originalButtonID }) {
                        correctedConfiguration.buttonSeat = button.seat
                    }
                    if changed.configuration != correctedConfiguration {
                        changed.configuration = correctedConfiguration; derivedChanged = true
                    }
                    if case .settlement = request, old.id == sourceHandID, derivedChanged {
                        throw SessionError.invalid("更正手的起始快照与场次来源不一致；请先更正前序记录。")
                    }
                    if derivedChanged { changed.touch() }
                    let structure = HandReducer.configurationIssues(changed)
                    if !structure.isEmpty {
                        if case .event = request { requireRepair(structure); continue }
                        throw SessionError.invalid("第 \(number) 手：" + structure.joined(separator: "；"))
                    }
                    let projection = HandReducer.project(changed)
                    handIssues = projection.issues.map(\.message)
                    if !handIssues.isEmpty && !allowDraftConflicts {
                        if case .event = request { requireRepair(handIssues); continue }
                        throw SessionError.invalid("第 \(number) 手原行动不能合法重放：" + handIssues.joined(separator: "；"))
                    }
                    // Explicit settlement correction is already confirmed; otherwise reuse only unchanged pot outcomes.
                    let explicitSettlement: Bool
                    if case .settlement = request { explicitSettlement = old.id == sourceHandID } else { explicitSettlement = false }
                    if let resolution {
                        if let selections = resolution.settlementSelections {
                            do { changed = try HandSettlement.confirm(changed, selections: selections, correction: true); replayed = true }
                            catch { requireRepair(["请核对本手结果：\(error.localizedDescription)"]); continue }
                        } else {
                            if changed.settlement?.invalidatedAt == nil { changed.settlement?.invalidatedAt = Date() }
                            handIssues.append("本手结果明确保留待核对，后续余额继承未知。")
                        }
                    }
                    if resolution == nil, !explicitSettlement, let prior = old.settlement, prior.isCurrent(for: old),
                       changed.revision != old.revision {
                        if handIssues.isEmpty {
                            do {
                                changed = try replaySettlement(changed, previous: prior)
                                replayed = true
                            } catch {
                                if !allowDraftConflicts {
                                    if case .event = request { requireRepair(["原结算无法沿用：\(error.localizedDescription)"]); continue }
                                    throw SessionError.invalid("第 \(number) 手结算需核对：\(error.localizedDescription)")
                                }
                                handIssues.append("旧结算已失效：\(error.localizedDescription)")
                            }
                        } else { handIssues.append("旧结算已失效，余额待核对。") }
                    }
                    if old.id == sourceHandID || derivedChanged || resolution != nil {
                        replacements.append(changed)
                        let playerIDs = old.players.map(\.id) + changed.players.filter { new in !old.players.contains(where: { $0.id == new.id }) }.map(\.id)
                        let players = playerIDs.map { id in
                            let before = old.players.first { $0.id == id }
                            let after = changed.players.first { $0.id == id }
                            return SessionCorrectionPlayerImpact(playerID: id, previouslyDealt: before != nil, proposedDealt: after != nil,
                                previousSeat: before?.seat ?? after?.seat ?? 0, proposedSeat: after?.seat ?? before?.seat ?? 0,
                                previousStart: before?.startingStack ?? .unknown, proposedStart: after?.startingStack ?? .unknown,
                                previousEnd: currentBalance(old, playerID: id), proposedEnd: currentBalance(changed, playerID: id))
                        }
                        impacts.append(.init(handID: changed.id, number: number, previousConfiguration: old.configuration, proposedConfiguration: changed.configuration, previousGameFormat: old.gameFormat, proposedGameFormat: changed.gameFormat, players: players, settlementReplayed: replayed || explicitSettlement, issues: handIssues))
                    }
                }
                for player in changed.players {
                    if let index = seats.firstIndex(where: { $0.playerID == player.id }) { seats[index].balance = currentBalance(changed, playerID: player.id) }
                }
            }
            let originals = replacements.compactMap { replacement in allHands.first(where: { $0.id == replacement.id }) }
            candidate.corrections = (candidate.corrections ?? []) + [.init(reason: reason, previousEvents: originalSession.events, previousHands: originals,
                previousInitialConfiguration: originalSession.initialConfiguration, previousInitialSeats: originalSession.initialSeats)]
            candidate.updatedAt = Date()
            var completeHands = allHands
            for replacement in replacements {
                if let index = completeHands.firstIndex(where: { $0.id == replacement.id }) { completeHands[index] = replacement }
            }
            if requiredRepairs.isEmpty { try validateStoredSession(candidate, hands: completeHands) }
            else { conflicts.append("还有 \(requiredRepairs.count) 手需要明确修正名单、事实或结果。") }
        } catch { conflicts.append(error.localizedDescription) }
        return .init(request: request, sessionID: originalSession.id, baseline: baseline, session: candidate, hands: replacements, impacts: impacts, eventImpacts: eventImpacts, conflicts: conflicts, requiredRepairs: requiredRepairs, revisionHighWatermarks: revisionHighWatermarks)
    }

    private static func currentBalance(_ hand: HandRecord, playerID: UUID) -> ChipAmount {
        guard let settlement = hand.settlement, settlement.isCurrent(for: hand) else { return .unknown }
        return settlement.finalBalances.first(where: { $0.playerID == playerID })?.amount ?? .unknown
    }
    private static func replaySettlement(_ hand: HandRecord, previous: HandSettlementRecord) throws -> HandRecord {
        var selections: [Int: SettlementSelection] = [:]
        for pot in previous.pots { selections[pot.id] = .init(winnerIDs: pot.winnerIDs, oddChipFirst: pot.oddChipFirst, amountInputs: pot.amountInputs) }
        let preview = HandSettlement.preview(hand, selections: selections)
        guard preview.canConfirm else { throw SessionError.invalid(preview.issues.joined(separator: "；")) }
        func samePayments(_ a: [SettlementPayment], _ b: [SettlementPayment]) -> Bool {
            a.count == b.count && a.allSatisfy { item in b.contains { $0.playerID == item.playerID && $0.units == item.units } }
        }
        guard samePayments(preview.refunds, previous.refunds), preview.pots.count == previous.pots.count,
              zip(preview.pots, previous.pots).allSatisfy({ a, b in
                  a.id == b.id && a.units == b.units && Set(a.eligibleIDs) == Set(b.eligibleIDs) && Set(a.winnerIDs) == Set(b.winnerIDs)
                    && samePayments(a.payments, b.payments)
              }) else { throw SessionError.invalid("池金额、资格、退款或原获奖分配已改变，不能自动沿用原结算。") }
        return try HandSettlement.confirm(hand, selections: selections, correction: true)
    }
}
