import Foundation

enum SettlementSource: String, Codable, Sendable { case fold, automaticShowdown, manual, mixed }
struct SettlementPayment: Codable, Sendable, Identifiable {
    var playerID: UUID
    var units: Int64
    var id: UUID { playerID }
}
struct SettlementBalance: Codable, Sendable, Identifiable {
    var playerID: UUID
    var amount: ChipAmount
    var id: UUID { playerID }
}
struct SettlementSelection: Sendable {
    var winnerIDs: [UUID]
    var oddChipFirst: UUID? = nil
    /// nil keeps the automatic split. Raw text reaches the domain so invalid drafts cannot be confirmed.
    var amountInputs: [SettlementAmountInput]? = nil
}
struct SettlementAmountInput: Codable, Sendable, Identifiable {
    var playerID: UUID
    var amount: String
    var id: UUID { playerID }
}
struct SettlementAmountCheck: Sendable, Identifiable {
    var id: Int
    var expectedUnits: Int64
    /// nil means an incomplete, invalid or overflowing amount draft, never a zero allocation.
    var allocatedUnits: Int64?
    var difference: Int64? { allocatedUnits.map { expectedUnits - $0 } }
}
struct SettledPot: Codable, Sendable, Identifiable {
    var id: Int
    var units: Int64
    var eligibleIDs: [UUID]
    var winnerIDs: [UUID]
    var payments: [SettlementPayment]
    var source: SettlementSource
    var oddChipFirst: UUID?
    /// Optional for old backups; preserves the explicitly checked amounts separately from winner evidence.
    var amountInputs: [SettlementAmountInput]? = nil
    /// Historical facts may later use a different unit; entered amounts retain their original interpretation.
    var amountInputUnit: ChipUnit? = nil
}
struct HandSettlementRecord: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var factRevision: Int
    var confirmedAt: Date = Date()
    var source: SettlementSource
    var refunds: [SettlementPayment]
    var pots: [SettledPot]
    var finalBalances: [SettlementBalance]
    var invalidatedAt: Date? = nil
    func isCurrent(for hand: HandRecord) -> Bool { hand.ruleApplicabilityIssue == nil && invalidatedAt == nil && factRevision == hand.revision }
}
struct SettlementPreview: Sendable {
    var pots: [SettledPot] = []
    var refunds: [SettlementPayment] = []
    var finalBalances: [SettlementBalance] = []
    var issues: [String] = []
    var source: SettlementSource = .manual
    var amountChecks: [SettlementAmountCheck] = []
    var canConfirm: Bool { issues.isEmpty && !finalBalances.isEmpty }
    var distributedUnits: Int64 { pots.reduce(0) { $0 + $1.units } }
    var allocatedUnits: Int64? {
        guard amountChecks.count == pots.count else { return nil }
        var total: Int64 = 0
        for check in amountChecks {
            guard let units = check.allocatedUnits else { return nil }
            let addition = total.addingReportingOverflow(units)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }
}
enum SettlementError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}

enum HandSettlement {
    static func preview(_ hand: HandRecord, selections: [Int: SettlementSelection] = [:]) -> SettlementPreview {
        var result = SettlementPreview()
        let projection = HandReducer.project(hand)
        let state = projection.latest
        guard !state.blocked, projection.issues.isEmpty else {
            result.issues = ["请先修正牌局缺项或冲突，再结算。"]
            return result
        }
        guard state.handComplete || (state.street == .river && state.roundComplete) else {
            result.issues = ["尚未到结算时点：完成行动和公共牌，或记录其余玩家弃牌。"]
            return result
        }
        guard state.pot.certainty == .exact, let totalPot = state.pot.units,
              state.players.allSatisfy({ $0.totalContribution.certainty == .exact && $0.totalContribution.units != nil }) else {
            result.issues = ["投入金额存在近似或未知，无法确认守恒结算；请先核对投入。"]
            return result
        }
        let eligible = state.players.filter { !$0.folded }.map(\.id)
        guard !eligible.isEmpty else { result.issues = ["没有合法争池玩家。"]; return result }
        var live = Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, $0.totalContribution.units ?? 0) })
        var deadTotal: Int64 = 0
        for node in projection.nodes where node.issues.isEmpty && (node.event.kind == .ante || node.event.kind == .deadBlind) {
            guard let id = node.event.playerID, let amount = node.event.amount?.units else { continue }
            live[id, default: 0] -= amount
            deadTotal += amount
        }
        // Refund live wagers street by street. Antes and dead blinds can never create an uncalled refund.
        var refunds: [UUID: Int64] = [:]
        for street in HandStreet.allCases {
            guard let end = projection.nodes.last(where: { $0.after.street == street })?.after else { continue }
            let contributions = end.players.map { ($0.id, $0.streetContribution.units ?? 0) }.sorted { $0.1 > $1.1 }
            guard let highest = contributions.first, highest.1 > 0 else { continue }
            let second = contributions.dropFirst().first?.1 ?? 0
            let excess = highest.1 - second
            if excess > 0 { refunds[highest.0, default: 0] += excess; live[highest.0, default: 0] -= excess }
        }
        result.refunds = hand.players.compactMap { p in refunds[p.id].map { .init(playerID: p.id, units: $0) } }
        guard live.values.allSatisfy({ $0 >= 0 }) else { result.issues = ["退回金额超出玩家实际投入。"]; return result }
        var layers: [(Int64, [UUID])] = []
        if deadTotal > 0 {
            let deadEligible = eligible.filter { id in (state.player(id)?.totalContribution.units ?? 0) > 0 }
            guard !deadEligible.isEmpty else { result.issues = ["死钱底池没有合法参与者。"]; return result }
            layers.append((deadTotal, deadEligible))
        }
        let levels = Set(live.values.filter { $0 > 0 }).sorted()
        var previous: Int64 = 0
        for level in levels {
            let payers = live.filter { $0.value >= level }.map(\.key)
            let amount = (level - previous) * Int64(payers.count)
            let qualified = eligible.filter { (live[$0] ?? 0) >= level }
            // A fold winner also receives folded contributions above their own prior commitment.
            let winners = eligible.count == 1 ? eligible : qualified
            if winners.isEmpty { result.issues.append("存在无人有资格领取的底池层，请核对投入及弃牌记录。"); return result }
            if let last = layers.last, Set(last.1) == Set(winners) {
                layers[layers.count - 1].0 += amount
            } else { layers.append((amount, winners)) }
            previous = level
        }
        let returned = refunds.values.reduce(0, +)
        guard layers.reduce(0, { $0 + $1.0 }) + returned == totalPot else {
            result.issues = ["可分配池加退回金额与事件底池不守恒。"]
            return result
        }
        if selections.keys.contains(where: { !layers.indices.contains($0) }) {
            result.issues.append("结算选择引用了不存在的底池，请重新核对。")
        }
        var winnings: [UUID: Int64] = [:]
        let seatOrder = HandReducer.clockwise(hand.players, after: hand.configuration.buttonSeat).map(\.id)
        for (index, layer) in layers.enumerated() {
            var winners: [UUID] = []
            var source: SettlementSource = .manual
            if layer.1.count == 1 {
                winners = layer.1
                source = state.handComplete ? .fold : .automaticShowdown
            } else if state.board.count == 5 && layer.1.allSatisfy({ id in hand.players.first { $0.id == id }?.holeCards.count == 2 }) {
                var scores: [UUID: PokerHandValue] = [:]
                do {
                    for id in layer.1 {
                        let cards = state.board + (hand.players.first { $0.id == id }?.holeCards ?? [])
                        scores[id] = try PokerEvaluator.evaluate(cards.map { card in (card.rank - 2) * 4 + (CardSuit.allCases.firstIndex(of: card.suit) ?? 0) })
                    }
                    guard let best = scores.values.max() else { throw SettlementError.invalid("无法评估摊牌。") }
                    winners = layer.1.filter { scores[$0] == best }
                    source = .automaticShowdown
                } catch { result.issues.append("摊牌牌张不能评估，请核对重复牌与缺项。") }
            }
            let automatic = !winners.isEmpty
            if let selection = selections[index] {
                let selected = selection.winnerIDs
                if selected.isEmpty || Set(selected).count != selected.count || !Set(selected).isSubset(of: Set(layer.1)) {
                    result.issues.append("第 \(index + 1) 池必须选择至少一位有资格的赢家。")
                } else if automatic && Set(selected) != Set(winners) {
                    result.issues.append("第 \(index + 1) 池选择与已知牌张或唯一赢家冲突；请修正事实。")
                } else { winners = selected }
            }
            var payments: [SettlementPayment] = []
            var oddFirst: UUID? = nil
            if winners.isEmpty {
                result.issues.append("第 \(index + 1) 池底牌不完整，请指定实际赢家。")
            } else {
                var ordered = seatOrder.filter { winners.contains($0) }
                let base = layer.0 / Int64(winners.count)
                let remainder = Int(layer.0 % Int64(winners.count))
                if let requested = selections[index]?.oddChipFirst {
                    if !winners.contains(requested) { result.issues.append("零头只能分配给本池赢家。") }
                    else if let start = ordered.firstIndex(of: requested) { ordered = Array(ordered[start...]) + Array(ordered[..<start]) }
                }
                oddFirst = remainder > 0 ? ordered.first : nil
                for (offset, id) in ordered.enumerated() {
                    let paid = base + (offset < remainder ? 1 : 0)
                    payments.append(.init(playerID: id, units: paid))
                }
            }
            let inputs = selections[index]?.amountInputs
            var allocated: Int64? = winners.isEmpty ? nil : layer.0
            if let inputs {
                let prefix = "第 \(index + 1) 池"
                if Set(inputs.map(\.playerID)).count != inputs.count || Set(inputs.map(\.playerID)) != Set(winners) {
                    result.issues.append("\(prefix)金额必须逐位填写本池赢家，不得包含重复玩家或其他收款者。")
                }
                var parsed: [SettlementPayment] = []
                var sum: Int64 = 0
                var validAmounts = true
                for input in inputs {
                    guard let units = hand.configuration.chipUnit.parse(input.amount)?.units else {
                        result.issues.append("\(prefix)\(hand.players.first { $0.id == input.playerID }?.name ?? "未知玩家")获奖金额须为非负金额，且是最小筹码单位的整数倍；请修正输入。")
                        validAmounts = false
                        continue
                    }
                    let addition = sum.addingReportingOverflow(units)
                    if addition.overflow {
                        result.issues.append("\(prefix)分配金额总和超出整数范围。")
                        validAmounts = false
                    } else { sum = addition.partialValue }
                    parsed.append(.init(playerID: input.playerID, units: units))
                }
                allocated = validAmounts ? sum : nil
                if validAmounts {
                    if sum != layer.0 {
                        let delta = layer.0 - sum
                        result.issues.append("\(prefix)分配总额\(delta > 0 ? "少" : "多") \(hand.configuration.chipUnit.format(units: abs(delta)))，请核对差额。")
                    } else if parsed.count != payments.count || !payments.allSatisfy({ expected in
                        parsed.contains { $0.playerID == expected.playerID && $0.units == expected.units }
                    }) {
                        result.issues.append("\(prefix)金额不符合本池平分与当前零头方案；请按合法分配填写，或先调整零头归属。")
                    }
                }
            }
            result.amountChecks.append(.init(id: index, expectedUnits: layer.0, allocatedUnits: allocated))
            result.pots.append(.init(id: index, units: layer.0, eligibleIDs: layer.1, winnerIDs: winners, payments: payments, source: source, oddChipFirst: oddFirst, amountInputs: inputs, amountInputUnit: inputs == nil ? nil : hand.configuration.chipUnit))
            for payment in payments { winnings[payment.playerID, default: 0] += payment.units }
        }
        let sources = Set(result.pots.map { $0.source.rawValue })
        result.source = sources.count == 1 ? (result.pots.first?.source ?? .manual) : .mixed
        if !result.issues.isEmpty { return result }
        for player in state.players {
            let credits = (refunds[player.id] ?? 0) + (winnings[player.id] ?? 0)
            let balance = player.remaining.adding(.init(units: credits, source: "结算退回与获奖"))
            if player.remaining.units != nil && balance.units == nil { result.issues.append("玩家结算余额超出整数范围。"); continue }
            result.finalBalances.append(.init(playerID: player.id, amount: balance))
        }
        // Monetary awards always conserve the pot. Unknown starting balances remain unknown.
        if result.pots.flatMap(\.payments).reduce(0, { $0 + $1.units }) + returned != totalPot || result.allocatedUnits != result.distributedUnits {
            result.issues.append("分配总额与底池不守恒。")
        }
        if !result.issues.isEmpty { result.finalBalances = [] }
        return result
    }
    static func confirm(_ hand: HandRecord, selections: [Int: SettlementSelection] = [:], correction: Bool = false) throws -> HandRecord {
        // Reopening an already confirmed result remains idempotent. Explicit drafts are always validated.
        if let existing = hand.settlement, existing.isCurrent(for: hand), !correction, selections.isEmpty { return hand }
        let preview = preview(hand, selections: selections)
        guard preview.canConfirm else { throw SettlementError.invalid(preview.issues.joined(separator: "\n")) }
        if let existing = hand.settlement, existing.isCurrent(for: hand), !correction { return hand }
        var saved = hand
        let confirmationTime = Date()
        if var old = saved.settlement {
            // Superseded results retain their original confirmation time and fact revision.
            // A previously current result becomes historical at this explicit correction.
            if old.invalidatedAt == nil { old.invalidatedAt = confirmationTime }
            saved.settlementHistory = (saved.settlementHistory ?? []) + [old]
        }
        saved.settlement = .init(factRevision: hand.revision, confirmedAt: confirmationTime, source: preview.source, refunds: preview.refunds, pots: preview.pots, finalBalances: preview.finalBalances)
        saved.updatedAt = confirmationTime
        return saved
    }
}
