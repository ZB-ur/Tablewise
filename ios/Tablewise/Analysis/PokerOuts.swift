import Foundation

nonisolated enum ImprovementTarget: String, CaseIterable, Sendable, Identifiable {
    case straight, flush, higherCategory, takeLead, loseShare
    var id: String { rawValue }
    var title: String {
        switch self {
        case .straight: "组成顺子"
        case .flush: "组成同花"
        case .higherCategory: "升至更高成牌类别"
        case .takeLead: "对已知对手转为独自领先"
        case .loseShare: "对已知对手失去部分或全部领先份额"
        }
    }
}
nonisolated struct ImprovementRunout: Sendable, Identifiable {
    let first: Int
    let second: Int
    var id: Int { first * 52 + second }
}
nonisolated struct ImprovementEvent: Sendable, Identifiable {
    let target: ImprovementTarget
    let alreadyAchieved: Bool
    let nextCards: [Int]
    let nextProbability: Double
    let byRiverProbability: Double
    /// Two-card-only paths: neither card alone satisfies the target on the current flop.
    /// Unordered pairs; each has two equally likely turn/river orders.
    let backdoorPaths: [ImprovementRunout]
    let backdoorProbability: Double
    var id: String { target.id }
}
nonisolated struct OutsReport: Sendable {
    let events: [ImprovementEvent]
    let unseenCount: Int
    let cardsToCome: Int
    let runoutCount: Int
    let elapsedSeconds: Double
    let currentCategory: PokerHandCategory
    let comparesKnownOpponents: Bool
    /// Union of straight, flush and category targets, with overlapping cards counted once.
    let combinedNextCards: [Int]
    let combinedByRiverProbability: Double
}
nonisolated enum PokerOuts {
    /// Uniform unseen-board event enumeration after known cards are removed. Opponent
    /// ranges do not condition these event probabilities. Known opponents, when supplied,
    /// are compared at this same board only; no future public card is read.
    static func analyze(hole: [Int], board: [Int], deadCards: [Int] = [],
                        knownOpponents: [[Int]] = []) throws -> OutsReport {
        let start = ProcessInfo.processInfo.systemUptime
        guard hole.count == 2, [3, 4, 5].contains(board.count), knownOpponents.allSatisfy({ $0.count == 2 }) else {
            throw EquityError.invalidCards
        }
        let known = hole + board + deadCards + knownOpponents.flatMap { $0 }
        guard known.allSatisfy({ (0..<52).contains($0) }), Set(known).count == known.count else { throw EquityError.invalidCards }
        let base = try PokerEvaluator.evaluate(hole + board)
        let cardsToCome = 5 - board.count
        let excluded = Set(known)
        let deck = (0..<52).filter { !excluded.contains($0) }
        guard deck.count >= cardsToCome else { throw EquityError.invalidCards }
        guard cardsToCome > 0 else {
            return OutsReport(events: [], unseenCount: deck.count, cardsToCome: 0, runoutCount: 0,
                              elapsedSeconds: ProcessInfo.processInfo.systemUptime - start, currentCategory: base.category,
                              comparesKnownOpponents: !knownOpponents.isEmpty, combinedNextCards: [], combinedByRiverProbability: 0)
        }
        func containsStraight(_ cards: [Int]) -> Bool {
            let ranks = Set(cards.map { $0 / 4 })
            if [12, 0, 1, 2, 3].allSatisfy(ranks.contains) { return true }
            return (0...8).contains { low in (low...(low + 4)).allSatisfy(ranks.contains) }
        }
        func containsFlush(_ cards: [Int]) -> Bool { (0..<4).contains { suit in cards.filter { $0 % 4 == suit }.count >= 5 } }
        func share(_ publicCards: [Int]) -> Double {
            let own = PokerEvaluator.evaluateValid(hole + publicCards).score
            let other = knownOpponents.map { PokerEvaluator.evaluateValid($0 + publicCards).score }
            guard let best = other.max(), own >= best else { return 0 }
            return 1 / Double(1 + other.filter { $0 == own }.count)
        }
        let baseShare = knownOpponents.isEmpty ? 0 : share(board)
        var targets: [ImprovementTarget] = [.straight, .flush, .higherCategory]
        if !knownOpponents.isEmpty {
            if baseShare < 1 { targets.append(.takeLead) }
            if baseShare > 0 { targets.append(.loseShare) }
        }
        let already = targets.map { target in
            switch target {
            case .straight: return containsStraight(hole + board)
            case .flush: return containsFlush(hole + board)
            default: return false
            }
        }
        func matches(_ publicCards: [Int]) -> [Bool] {
            let cards = hole + publicCards
            // Shared evaluator work for each runout.
            let category = PokerEvaluator.evaluateValid(cards).category
            let currentShare = knownOpponents.isEmpty ? 0 : share(publicCards)
            return targets.enumerated().map { index, target in
                if already[index] { return false }
                switch target {
                case .straight: return containsStraight(cards)
                case .flush: return containsFlush(cards)
                case .higherCategory: return category.rawValue > base.category.rawValue
                case .takeLead: return currentShare == 1
                case .loseShare: return currentShare < baseShare
                }
            }
        }
        var next = targets.map { _ in [Int]() }
        var nextMatches: [Int: [Bool]] = [:]
        for card in deck {
            try Task.checkCancellation()
            let outcomes = matches(board + [card])
            nextMatches[card] = outcomes
            for index in targets.indices where outcomes[index] { next[index].append(card) }
        }
        var success = [Int](repeating: 0, count: targets.count)
        var backdoors = targets.map { _ in [ImprovementRunout]() }
        var runouts = 0
        var combinedSuccess = 0
        if cardsToCome == 2 {
            for i in 0..<(deck.count - 1) {
                try Task.checkCancellation()
                for j in (i + 1)..<deck.count {
                    let outcomes = matches(board + [deck[i], deck[j]])
                    runouts += 1
                    if outcomes.prefix(3).contains(true) { combinedSuccess += 1 }
                    for index in targets.indices where outcomes[index] {
                        success[index] += 1
                        if nextMatches[deck[i]]?[index] == false && nextMatches[deck[j]]?[index] == false {
                            backdoors[index].append(ImprovementRunout(first: deck[i], second: deck[j]))
                        }
                    }
                }
            }
        } else {
            runouts = deck.count
            success = next.map(\.count)
            combinedSuccess = Set(next.prefix(3).flatMap { $0 }).count
        }
        return OutsReport(events: targets.enumerated().map { index, target in
            ImprovementEvent(target: target, alreadyAchieved: already[index], nextCards: next[index],
                             nextProbability: Double(next[index].count) / Double(deck.count),
                             byRiverProbability: Double(success[index]) / Double(runouts),
                             backdoorPaths: backdoors[index], backdoorProbability: Double(backdoors[index].count) / Double(runouts))
        }, unseenCount: deck.count, cardsToCome: cardsToCome, runoutCount: runouts,
                          elapsedSeconds: ProcessInfo.processInfo.systemUptime - start, currentCategory: base.category,
                          comparesKnownOpponents: !knownOpponents.isEmpty,
                          combinedNextCards: Set(next.prefix(3).flatMap { $0 }).sorted(),
                          combinedByRiverProbability: Double(combinedSuccess) / Double(runouts))
    }
}
