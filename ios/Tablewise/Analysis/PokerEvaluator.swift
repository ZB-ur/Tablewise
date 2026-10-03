import Foundation

/// Rank-major encoding: 0...3 = 2♣,2♦,2♥,2♠; 48...51 = A♣,A♦,A♥,A♠.
/// This boundary is independent of persisted card and hand models.
nonisolated enum PokerEvaluator {
    static func evaluate(_ cards: [Int]) throws -> PokerHandValue {
        guard (5...7).contains(cards.count), cards.allSatisfy({ (0..<52).contains($0) }), Set(cards).count == cards.count else {
            throw EquityError.invalidCards
        }
        return evaluateValid(cards)
    }

    static func evaluateValid(_ cards: [Int]) -> PokerHandValue {
        let sorted = cards.sorted { $0 / 4 > $1 / 4 || ($0 / 4 == $1 / 4 && $0 > $1) }
        var ranks = [[Int]](repeating: [], count: 13)
        var suits = [[Int]](repeating: [], count: 4)
        for card in sorted { ranks[card / 4].append(card); suits[card % 4].append(card) }
        func straight(_ source: [Int]) -> [Int]? {
            var byRank: [Int: Int] = [:]
            for c in source { byRank[c / 4] = c }
            for high in stride(from: 12, through: 4, by: -1) {
                let run = (0..<5).compactMap { byRank[high - $0] }
                if run.count == 5 { return run }
            }
            if let ace = byRank[12], let five = byRank[3], let four = byRank[2], let three = byRank[1], let two = byRank[0] {
                return [five, four, three, two, ace]
            }
            return nil
        }
        func value(_ category: PokerHandCategory, _ five: [Int], _ tie: [Int]? = nil) -> PokerHandValue {
            let digits = tie ?? five.map { $0 / 4 + 2 }
            var score = category.rawValue
            for index in 0..<5 { score = score * 15 + (index < digits.count ? digits[index] : 0) }
            return PokerHandValue(category: category, bestFive: five, score: score)
        }
        if let flush = suits.first(where: { $0.count >= 5 }), let run = straight(flush) {
            return value(.straightFlush, run, [run[0] / 4 + 2])
        }
        let descending = Array((0..<13).reversed())
        if let quad = descending.first(where: { ranks[$0].count == 4 }) {
            let kicker = sorted.first { $0 / 4 != quad }!
            return value(.fourOfAKind, ranks[quad] + [kicker], [quad + 2, kicker / 4 + 2])
        }
        let trips = descending.filter { ranks[$0].count >= 3 }
        if let trip = trips.first, let pair = descending.first(where: { $0 != trip && ranks[$0].count >= 2 }) {
            return value(.fullHouse, Array(ranks[trip].prefix(3)) + Array(ranks[pair].prefix(2)), [trip + 2, pair + 2])
        }
        if let flush = suits.first(where: { $0.count >= 5 }) { return value(.flush, Array(flush.prefix(5))) }
        if let run = straight(sorted) { return value(.straight, run, [run[0] / 4 + 2]) }
        if let trip = trips.first {
            let kickers = Array(sorted.filter { $0 / 4 != trip }.prefix(2))
            return value(.threeOfAKind, ranks[trip] + kickers, [trip + 2] + kickers.map { $0 / 4 + 2 })
        }
        let pairs = descending.filter { ranks[$0].count >= 2 }
        if pairs.count >= 2 {
            let p = pairs[0], q = pairs[1]
            let kicker = sorted.first { $0 / 4 != p && $0 / 4 != q }!
            return value(.twoPair, Array(ranks[p].prefix(2)) + Array(ranks[q].prefix(2)) + [kicker], [p + 2, q + 2, kicker / 4 + 2])
        }
        if let pair = pairs.first {
            let kickers = Array(sorted.filter { $0 / 4 != pair }.prefix(3))
            return value(.onePair, ranks[pair] + kickers, [pair + 2] + kickers.map { $0 / 4 + 2 })
        }
        return value(.highCard, Array(sorted.prefix(5)))
    }
}

nonisolated enum PokerHandCategory: Int, Codable, Sendable, CaseIterable {
    case highCard, onePair, twoPair, threeOfAKind, straight, flush, fullHouse, fourOfAKind, straightFlush
    var title: String {
        ["高牌", "一对", "两对", "三条", "顺子", "同花", "葫芦", "四条", "同花顺"][rawValue]
    }
}

nonisolated struct PokerHandValue: Sendable, Equatable, Comparable {
    let category: PokerHandCategory
    let bestFive: [Int]
    let score: Int
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.score < rhs.score }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.score == rhs.score }
}
