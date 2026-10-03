import Foundation

nonisolated struct WeightedCombo: Sendable, Hashable {
    let first: Int
    let second: Int
    let weight: Double
    init(_ first: Int, _ second: Int, weight: Double = 1) {
        self.first = min(first, second); self.second = max(first, second); self.weight = weight
    }
    var mask: UInt64 { (UInt64(1) << first) | (UInt64(1) << second) }
}

nonisolated struct EquityPlayer: Sendable {
    let id: String
    /// nil is unknown. Empty/all-zero is an explicitly empty range, never zero equity.
    let range: [WeightedCombo]?
}
nonisolated struct EquityPot: Sendable {
    let id: String
    let eligiblePlayerIDs: [String]
}
nonisolated struct EquitySettings: Sendable {
    var exactStateLimit: Int = 100_000
    var sampleCount: Int = 10_000
    var maximumAttempts: Int = 2_000_000
    var maximumSeconds: Double = 15
    var seed: UInt64 = 0x5441424C45574953
}
nonisolated struct EquityRequest: Sendable {
    let players: [EquityPlayer]
    let board: [Int]
    var deadCards: [Int] = []
    /// Empty means one common pot containing all supplied players.
    var pots: [EquityPot] = []
    var settings = EquitySettings()
}
nonisolated enum EquityError: Error, LocalizedError, Sendable, Equatable {
    case invalidCards, invalidRequest, invalidRange(String), missingRange(String), emptyRange(String)
    case blockedRange(String), noJointAssignment, samplingExhausted, timeLimit
    var errorDescription: String? {
        switch self {
        case .invalidCards: "牌张重复、超出范围或数量不合法"
        case .invalidRequest: "计算人数、底池资格或参数不合法"
        case .invalidRange(let id): "\(id) 的组合或权重不合法"
        case .missingRange(let id): "\(id) 缺少手牌或范围假设"
        case .emptyRange(let id): "\(id) 的范围权重全为零，无法计算"
        case .blockedRange(let id): "\(id) 的所有组合均与已知牌冲突"
        case .noJointAssignment: "各玩家范围之间无合法联合发牌组合"
        case .samplingExhausted: "抽样未获得合法样本，请缩小范围或重试"
        case .timeLimit: "计算达到时间限制，请缩小范围或重试"
        }
    }
}
nonisolated struct EquityShare: Sendable {
    let playerID: String
    let equity: Double
    let winProbability: Double
    /// Probability of being among two or more tied winners (not fractional share).
    let tieProbability: Double
    /// Estimated standard error of fractional pot share; nil for exact enumeration or one sample.
    let equityStandardError: Double?
}
nonisolated struct EquityPotResult: Sendable {
    let potID: String
    /// Ineligible players are absent, never given a claim on the pot.
    let shares: [EquityShare]
}
nonisolated struct EquityResult: Sendable {
    enum Method: String, Sendable { case exact, monteCarlo }
    enum Completion: String, Sendable { case complete, timeBudget, attemptBudget }
    let pots: [EquityPotResult]
    let method: Method
    let completion: Completion
    let samples: Int
    let attempts: Int
    let elapsedSeconds: Double
    let seed: UInt64
}

/// No future-board or revealed-card policy is inferred here: caller must supply a D04-scoped snapshot.
/// Run off the UI actor (e.g. Task.detached); cancellation throws CancellationError, never old results.
nonisolated enum EquityEngine {
    static func calculate(_ request: EquityRequest) async throws -> EquityResult {
        try calculateSynchronously(request)
    }

    static func calculateSynchronously(_ request: EquityRequest) throws -> EquityResult {
        let start = ProcessInfo.processInfo.systemUptime
        let config = request.settings
        guard (2...9).contains(request.players.count), Set(request.players.map(\.id)).count == request.players.count,
              config.exactStateLimit >= 0, config.sampleCount > 0, config.maximumAttempts > 0,
              config.maximumSeconds.isFinite, config.maximumSeconds > 0 else { throw EquityError.invalidRequest }
        guard [0, 3, 4, 5].contains(request.board.count) else { throw EquityError.invalidCards }
        let known = request.board + request.deadCards
        guard known.allSatisfy({ (0..<52).contains($0) }), Set(known).count == known.count,
              known.count + request.players.count * 2 + 5 - request.board.count <= 52 else { throw EquityError.invalidCards }
        let initialMask = known.reduce(UInt64(0)) { $0 | UInt64(1) << $1 }
        let ranges: [[WeightedCombo]] = try request.players.map { player in
            guard let input = player.range else { throw EquityError.missingRange(player.id) }
            var seen = Set<Int>()
            for combo in input {
                guard (0..<52).contains(combo.first), (0..<52).contains(combo.second), combo.first != combo.second,
                      combo.weight.isFinite, combo.weight >= 0,
                      seen.insert(combo.first * 52 + combo.second).inserted else { throw EquityError.invalidRange(player.id) }
            }
            let positive = input.filter { $0.weight > 0 }
            guard !positive.isEmpty else { throw EquityError.emptyRange(player.id) }
            let legal = positive.filter { $0.mask & initialMask == 0 }
            guard !legal.isEmpty else { throw EquityError.blockedRange(player.id) }
            // Preserve every finite positive input: normalizing first can underflow a
            // tiny legal combo to zero before joint conflicts remove larger combos.
            return legal
        }
        let pots = request.pots.isEmpty ? [EquityPot(id: "main", eligiblePlayerIDs: request.players.map(\.id))] : request.pots
        guard Set(pots.map(\.id)).count == pots.count else { throw EquityError.invalidRequest }
        let eligible: [[Int]] = try pots.map { pot in
            guard !pot.eligiblePlayerIDs.isEmpty, Set(pot.eligiblePlayerIDs).count == pot.eligiblePlayerIDs.count else { throw EquityError.invalidRequest }
            return try pot.eligiblePlayerIDs.map { id in
                guard let index = request.players.firstIndex(where: { $0.id == id }) else { throw EquityError.invalidRequest }
                return index
            }
        }
        var shares = pots.map { _ in [Double](repeating: 0, count: ranges.count) }
        var wins = shares, ties = shares, squaredShares = shares
        var totalWeight = 0.0
        var logWeightScale = -Double.infinity
        var samples = 0, attempts = 0
        var chosen: [WeightedCombo] = []
        let missing = 5 - request.board.count
        let deckCount = 52 - known.count - ranges.count * 2
        var bound = 1.0
        for range in ranges { bound *= Double(range.count) }
        if missing > 0 { for i in 0..<missing { bound *= Double(deckCount - i) / Double(i + 1) } }
        let exact = bound <= Double(config.exactStateLimit)
        func checkBudget() throws {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime - start >= config.maximumSeconds { throw EquityError.timeLimit }
        }
        func record(_ board: [Int], _ logWeight: Double) {
            // Online log-sum-exp scaling. The largest legal joint weight seen so
            // far has scaled weight 1, even if its unscaled product is < 5e-324.
            // All accumulators share that scale, so their ratios are unchanged.
            if logWeight > logWeightScale {
                let scale = exp(logWeightScale - logWeight)
                totalWeight *= scale
                for pot in shares.indices {
                    for player in shares[pot].indices {
                        shares[pot][player] *= scale
                        wins[pot][player] *= scale
                        ties[pot][player] *= scale
                        squaredShares[pot][player] *= scale
                    }
                }
                logWeightScale = logWeight
            }
            let weight = exp(logWeight - logWeightScale)
            let values = chosen.map { PokerEvaluator.evaluateValid(board + [$0.first, $0.second]).score }
            for (pot, players) in eligible.enumerated() {
                let best = players.map { values[$0] }.max()!
                let winners = players.filter { values[$0] == best }
                for winner in winners {
                    let fraction = 1 / Double(winners.count)
                    shares[pot][winner] += weight * fraction
                    squaredShares[pot][winner] += weight * fraction * fraction
                    if winners.count == 1 { wins[pot][winner] += weight } else { ties[pot][winner] += weight }
                }
            }
            totalWeight += weight; samples += 1
        }
        func enumerateBoards(_ deck: [Int], _ index: Int, _ board: [Int], _ logWeight: Double) throws {
            if board.count == 5 {
                attempts += 1
                if attempts % 128 == 0 { try checkBudget() }
                record(board, logWeight); return
            }
            let needed = 5 - board.count
            guard index <= deck.count - needed else { return }
            for i in index...(deck.count - needed) { try enumerateBoards(deck, i + 1, board + [deck[i]], logWeight) }
        }
        func enumerateHands(_ index: Int, _ mask: UInt64, _ logWeight: Double) throws {
            try checkBudget()
            if index == ranges.count {
                let deck = (0..<52).filter { mask & (UInt64(1) << $0) == 0 }
                try enumerateBoards(deck, 0, request.board, logWeight); return
            }
            for combo in ranges[index] where combo.mask & mask == 0 {
                chosen.append(combo)
                try enumerateHands(index + 1, mask | combo.mask, logWeight + log(combo.weight))
                chosen.removeLast()
            }
        }
        var completion = EquityResult.Completion.complete
        if exact {
            try enumerateHands(0, initialMask, 0)
            guard samples > 0, totalWeight > 0 else { throw EquityError.noJointAssignment }
        } else {
            // Establish feasibility separately. An exhausted random budget is NOT proof of an empty joint range.
            var feasibilityVisits = 0
            func feasible(_ index: Int, _ mask: UInt64) throws -> Bool {
                feasibilityVisits += 1
                if feasibilityVisits % 128 == 0 { try checkBudget() }
                if index == ranges.count { return true }
                for combo in ranges[index] where combo.mask & mask == 0 {
                    if try feasible(index + 1, mask | combo.mask) { return true }
                }
                return false
            }
            guard try feasible(0, initialMask) else { throw EquityError.noJointAssignment }
            var random = EquityRandom(seed: config.seed)
            let cumulative = ranges.map { range -> [Double] in
                let largest = range.map { log($0.weight) }.max()!
                let scaled = range.map { exp(log($0.weight) - largest) }
                let total = scaled.reduce(0, +)
                var sum = 0.0
                var result = scaled.map { sum += $0 / total; return sum }
                result[result.count - 1] = 1
                return result
            }
            while samples < config.sampleCount && attempts < config.maximumAttempts {
                if attempts % 128 == 0 {
                    try Task.checkCancellation()
                    if ProcessInfo.processInfo.systemUptime - start >= config.maximumSeconds { completion = .timeBudget; break }
                }
                attempts += 1; chosen.removeAll(keepingCapacity: true)
                var mask = initialMask
                var conflict = false
                // Draw independently from original distributions, reject the entire joint assignment.
                // Sequential conditional renormalization would bias overlapping weighted ranges.
                for index in ranges.indices {
                    let draw = random.unit()
                    var low = 0, high = cumulative[index].count - 1
                    while low < high {
                        let mid = (low + high) / 2
                        if draw < cumulative[index][mid] { high = mid } else { low = mid + 1 }
                    }
                    let combo = ranges[index][low]
                    if combo.mask & mask != 0 { conflict = true; break }
                    mask |= combo.mask; chosen.append(combo)
                }
                if conflict { continue }
                var deck = (0..<52).filter { mask & (UInt64(1) << $0) == 0 }
                var board = request.board
                for i in 0..<missing {
                    let j = i + random.integer(upperBound: deck.count - i)
                    deck.swapAt(i, j); board.append(deck[i])
                }
                record(board, 0)
            }
            guard samples > 0 else { throw EquityError.samplingExhausted }
            if samples < config.sampleCount && completion == .complete { completion = .attemptBudget }
        }
        try Task.checkCancellation()
        return EquityResult(pots: pots.enumerated().map { index, pot in
            EquityPotResult(potID: pot.id, shares: eligible[index].map { player in
                EquityShare(playerID: request.players[player].id, equity: shares[index][player] / totalWeight,
                            winProbability: wins[index][player] / totalWeight, tieProbability: ties[index][player] / totalWeight,
                            equityStandardError: exact || samples < 2 ? nil : sqrt(max(0, squaredShares[index][player] / totalWeight - pow(shares[index][player] / totalWeight, 2)) / Double(samples - 1)))
            })
        }, method: exact ? .exact : .monteCarlo, completion: completion, samples: samples, attempts: attempts,
                           elapsedSeconds: ProcessInfo.processInfo.systemUptime - start, seed: config.seed)
    }
}

nonisolated private struct EquityRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }
    mutating func integer(upperBound: Int) -> Int {
        let bound = UInt64(upperBound)
        let threshold = (UInt64(0) &- bound) % bound
        var value = next()
        while value < threshold { value = next() }
        return Int(value % bound)
    }
}
