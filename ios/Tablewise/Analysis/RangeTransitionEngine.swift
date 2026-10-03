import Foundation

nonisolated struct RangeTransitionCard: Sendable, Identifiable {
    let card: Int
    let observations: Int
    let leadCount: Int
    let dangerCount: Int
    var id: Int { card }
    var leadProbability: Double { Double(leadCount) / Double(observations) }
    var dangerProbability: Double { Double(dangerCount) / Double(observations) }
}
nonisolated struct RangeTransitionReport: Sendable {
    let potID: String
    let samples: Int
    let attempts: Int
    let elapsedSeconds: Double
    let seed: UInt64
    let reachedBudget: Bool
    let nextLeadProbability: Double
    let nextDangerProbability: Double
    let riverLeadProbability: Double
    let riverDangerProbability: Double
    let cards: [RangeTransitionCard]
}

/// Samples the explicitly supplied independent weighted ranges conditioned on joint
/// card compatibility. Rejects the WHOLE assignment; never sequentially renormalizes.
/// Events compare fractional showdown share, not betting EV. All range players' cards
/// block the deck, while winner comparisons use the specified subject's first eligible pot.
nonisolated enum RangeTransitionEngine {
    static func calculate(_ request: EquityRequest, subjectID: String) throws -> RangeTransitionReport {
        let start = ProcessInfo.processInfo.systemUptime
        guard [3, 4].contains(request.board.count), let subject = request.players.firstIndex(where: { $0.id == subjectID }),
              (2...9).contains(request.players.count), Set(request.players.map(\.id)).count == request.players.count else { throw EquityError.invalidRequest }
        let settings = request.settings
        guard settings.sampleCount > 0, settings.maximumAttempts > 0, settings.maximumSeconds.isFinite, settings.maximumSeconds > 0 else { throw EquityError.invalidRequest }
        let known = request.board + request.deadCards
        guard Set(known).count == known.count, known.allSatisfy({ (0..<52).contains($0) }), known.count + request.players.count * 2 + 5 - request.board.count <= 52 else { throw EquityError.invalidCards }
        let initialMask = known.reduce(UInt64(0)) { $0 | UInt64(1) << $1 }
        let ranges: [[WeightedCombo]] = try request.players.map { player in
            guard let range = player.range else { throw EquityError.missingRange(player.id) }
            var seen = Set<Int>()
            for combo in range {
                guard (0..<52).contains(combo.first), (0..<52).contains(combo.second), combo.first != combo.second,
                      combo.weight.isFinite, combo.weight >= 0, seen.insert(combo.first * 52 + combo.second).inserted else { throw EquityError.invalidRange(player.id) }
            }
            let positive = range.filter { $0.weight > 0 }
            guard !positive.isEmpty else { throw EquityError.emptyRange(player.id) }
            let legal = positive.filter { $0.mask & initialMask == 0 }
            guard !legal.isEmpty else { throw EquityError.blockedRange(player.id) }
            return legal
        }
        let pots = request.pots.isEmpty ? [EquityPot(id: "主池", eligiblePlayerIDs: request.players.map(\.id))] : request.pots
        guard let pot = pots.first(where: { $0.eligiblePlayerIDs.contains(subjectID) }),
              Set(pot.eligiblePlayerIDs).count == pot.eligiblePlayerIDs.count else { throw EquityError.invalidRequest }
        let participants = try pot.eligiblePlayerIDs.map { id in
            guard let index = request.players.firstIndex(where: { $0.id == id }) else { throw EquityError.invalidRequest }; return index
        }
        guard participants.count >= 2 else { throw EquityError.invalidRequest }
        var feasibilityVisits = 0
        func feasible(_ index: Int, _ mask: UInt64) throws -> Bool {
            feasibilityVisits += 1
            if feasibilityVisits % 128 == 0 {
                try Task.checkCancellation()
                if ProcessInfo.processInfo.systemUptime - start > settings.maximumSeconds { throw EquityError.timeLimit }
            }
            if index == ranges.count { return true }
            for combo in ranges[index] where combo.mask & mask == 0 {
                if try feasible(index + 1, mask | combo.mask) { return true }
            }
            return false
        }
        guard try feasible(0, initialMask) else { throw EquityError.noJointAssignment }
        let cumulative: [[Double]] = ranges.map { range in
            let largest = range.map { log($0.weight) }.max()!
            let scaled = range.map { exp(log($0.weight) - largest) }
            let total = scaled.reduce(0, +)
            var sum = 0.0
            var result = scaled.map { sum += $0 / total; return sum }
            result[result.count - 1] = 1
            return result
        }
        let seed = settings.seed ^ 0x4F555453
        var random = TransitionRandom(state: seed)
        var samples = 0, attempts = 0, leadNext = 0, dangerNext = 0, leadRiver = 0, dangerRiver = 0
        var cardCount = [Int](repeating: 0, count: 52), cardLead = cardCount, cardDanger = cardCount
        var budget = false
        var chosen: [WeightedCombo] = []
        func share(_ board: [Int]) -> Double {
            let own = PokerEvaluator.evaluateValid(board + [chosen[subject].first, chosen[subject].second]).score
            let values = participants.map { PokerEvaluator.evaluateValid(board + [chosen[$0].first, chosen[$0].second]).score }
            guard let best = values.max(), own == best else { return 0 }
            return 1 / Double(values.filter { $0 == best }.count)
        }
        while samples < settings.sampleCount && attempts < settings.maximumAttempts {
            if attempts % 64 == 0 {
                try Task.checkCancellation()
                if ProcessInfo.processInfo.systemUptime - start >= settings.maximumSeconds { budget = true; break }
            }
            attempts += 1; chosen.removeAll(keepingCapacity: true)
            var mask = initialMask
            var conflict = false
            for index in ranges.indices {
                let draw = random.unit()
                var low = 0, high = ranges[index].count - 1
                while low < high {
                    let middle = (low + high) / 2
                    if draw < cumulative[index][middle] { high = middle } else { low = middle + 1 }
                }
                let combo = ranges[index][low]
                if mask & combo.mask != 0 { conflict = true; break }
                mask |= combo.mask; chosen.append(combo)
            }
            if conflict { continue }
            var deck = (0..<52).filter { mask & (UInt64(1) << $0) == 0 }
            let base = share(request.board)
            let nextIndex = random.integer(deck.count)
            deck.swapAt(0, nextIndex)
            let nextCard = deck[0]
            var board = request.board + [nextCard]
            let next = share(board)
            if board.count == 4 { board.append(deck[1 + random.integer(deck.count - 1)]) }
            let river = share(board)
            let nextLeads = base < 1 && next == 1
            let nextDanger = base > 0 && next < base
            if nextLeads { leadNext += 1; cardLead[nextCard] += 1 }
            if nextDanger { dangerNext += 1; cardDanger[nextCard] += 1 }
            if base < 1 && river == 1 { leadRiver += 1 }
            if base > 0 && river < base { dangerRiver += 1 }
            cardCount[nextCard] += 1; samples += 1
        }
        try Task.checkCancellation()
        guard samples > 0 else { throw EquityError.samplingExhausted }
        budget = budget || samples < settings.sampleCount
        return RangeTransitionReport(potID: pot.id, samples: samples, attempts: attempts,
                                     elapsedSeconds: ProcessInfo.processInfo.systemUptime - start, seed: seed, reachedBudget: budget,
                                     nextLeadProbability: Double(leadNext) / Double(samples), nextDangerProbability: Double(dangerNext) / Double(samples),
                                     riverLeadProbability: Double(leadRiver) / Double(samples), riverDangerProbability: Double(dangerRiver) / Double(samples),
                                     cards: (0..<52).filter { cardCount[$0] > 0 }.map {
            RangeTransitionCard(card: $0, observations: cardCount[$0], leadCount: cardLead[$0], dangerCount: cardDanger[$0])
        })
    }
}
nonisolated private struct TransitionRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }
    mutating func integer(_ bound: Int) -> Int {
        let upper = UInt64(bound), threshold = (UInt64(0) &- UInt64(bound)) % UInt64(bound)
        var value = next(); while value < threshold { value = next() }
        return Int(value % upper)
    }
}
