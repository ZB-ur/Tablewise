import Foundation

/// Formula results describe explicitly supplied scenarios, not strategy recommendations.
nonisolated enum PokerMath {
    struct CallPrice: Sendable {
        let cost: Double
        let contestablePotAfterCall: Double
        let breakEvenEquity: Double
    }
    /// Only a single fully contestable pot, with no later action or investment.
    /// PotBeforeCall already contains the opponent's bet; callCost is incremental chips paid now.
    static func callPrice(potBeforeCall: Double, callCost: Double, singleContestablePot: Bool,
                          noFurtherInvestment: Bool, noPlayersBehind: Bool) -> CallPrice? {
        guard singleContestablePot, noFurtherInvestment, noPlayersBehind,
              valid(potBeforeCall), valid(callCost), potBeforeCall + callCost > 0 else { return nil }
        let after = potBeforeCall + callCost
        guard after.isFinite else { return nil }
        return CallPrice(cost: callCost, contestablePotAfterCall: after, breakEvenEquity: callCost / after)
    }
    /// Relative to folding now; equity includes split-pot share. Never compares with raising.
    static func conditionalCallEV(equity: Double, price: CallPrice) -> Double? {
        guard equity.isFinite, (0...1).contains(equity), valid(price.cost),
              valid(price.contestablePotAfterCall) else { return nil }
        return equity * price.contestablePotAfterCall - price.cost
    }
    static func spr(effectiveStackAtSameInstant: Double, potAtSameInstant: Double,
                    hasUnmatchedInvestment: Bool = false) -> Double? {
        guard !hasUnmatchedInvestment, valid(effectiveStackAtSameInstant), valid(potAtSameInstant), potAtSameInstant > 0 else { return nil }
        return effectiveStackAtSameInstant / potAtSameInstant
    }
    struct CalledBetScenario: Sendable {
        let potAfterCall: Double
        let bettorRemaining: Double
        let callerRemaining: Double
        let spr: Double
        let opponentCallPrice: Double
    }
    /// Heads-up first bet only, no existing street wager. Both players cover the supplied amount.
    static func calledBet(pot: Double, bettorStack: Double, callerStack: Double, bet: Double,
                          headsUpFirstBet: Bool) -> CalledBetScenario? {
        guard headsUpFirstBet, [pot, bettorStack, callerStack, bet].allSatisfy(valid),
              bet <= min(bettorStack, callerStack), pot + 2 * bet > 0, (pot + 2 * bet).isFinite else { return nil }
        let after = pot + 2 * bet
        return CalledBetScenario(potAfterCall: after, bettorRemaining: bettorStack - bet,
                                 callerRemaining: callerStack - bet, spr: (min(bettorStack, callerStack) - bet) / after,
                                 opponentCallPrice: bet / after)
    }
    static func alphaMDF(pot: Double, bet: Double, headsUpFirstBet: Bool) -> (alpha: Double, mdf: Double)? {
        guard headsUpFirstBet, valid(pot), valid(bet), pot + bet > 0, (pot + bet).isFinite else { return nil }
        return (bet / (pot + bet), pot / (pot + bet))
    }
    private static func valid(_ value: Double) -> Bool { value.isFinite && value >= 0 }
}

nonisolated struct FlushImprovement: Sendable {
    let suit: Int
    /// All one-card outs, deduplicated and excluding every supplied known/dead card.
    let outs: [Int]
    let unseenCount: Int
    let nextCardProbability: Double
    let byRiverProbability: Double
    let cardsToCome: Int
}
nonisolated enum PokerImprovement {
    /// A four-card flush draw only. This is a flush-making event, NOT winning equity.
    /// Board-only flush possibilities may occur; callers must identify that to users.
    /// Unknown (missing hole cards), no draw, made flush and river return nil, not fictitious outs.
    static func flushDraw(hole: [Int], board: [Int], otherKnownCards: [Int] = []) throws -> FlushImprovement? {
        guard hole.count == 2, [3, 4, 5].contains(board.count) else { return nil }
        let known = hole + board + otherKnownCards
        guard known.allSatisfy({ (0..<52).contains($0) }), Set(known).count == known.count else { throw EquityError.invalidCards }
        guard board.count < 5 else { return nil }
        let live = hole + board
        guard let suit = (0..<4).first(where: { suit in live.filter { $0 % 4 == suit }.count == 4 }) else { return nil }
        let excluded = Set(known)
        let outs = (0..<52).filter { $0 % 4 == suit && !excluded.contains($0) }
        let remaining = 52 - known.count
        let draws = 5 - board.count
        guard remaining >= draws else { throw EquityError.invalidCards }
        var miss = 1.0
        for i in 0..<draws { miss *= Double(max(0, remaining - outs.count - i)) / Double(remaining - i) }
        return FlushImprovement(suit: suit, outs: outs, unseenCount: remaining,
                                nextCardProbability: Double(outs.count) / Double(remaining),
                                byRiverProbability: 1 - miss, cardsToCome: draws)
    }
}
