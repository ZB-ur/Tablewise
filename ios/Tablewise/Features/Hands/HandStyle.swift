import SwiftUI

enum HandStyle {
    static let canvas = Color(red: 0.963, green: 0.959, blue: 0.946)
    static let ink = Color(red: 0.20, green: 0.22, blue: 0.21)
    static let muted = Color(red: 0.47, green: 0.48, blue: 0.45)
    static let line = Color(red: 0.89, green: 0.89, blue: 0.87)
    static let green = Color(red: 0.23, green: 0.47, blue: 0.37)
    static let gold = Color(red: 0.59, green: 0.43, blue: 0.11)
    static let red = Color(red: 0.68, green: 0.32, blue: 0.27)
    static let blue = Color(red: 0.27, green: 0.43, blue: 0.59)
    static func color(_ kind: HandEventKind) -> Color {
        switch kind {
        case .call: green
        case .bet: blue
        case .raiseTo: gold
        case .allIn: red
        default: muted
        }
    }
}

extension View {
    func handPanel() -> some View {
        padding(16).background(.white, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct HandPortrait: View {
    var seat: Int
    var hero: Bool = false
    var folded: Bool = false
    var allIn: Bool = false
    var size: CGFloat = 34
    var body: some View {
        Image("Portrait\((max(0, seat) % 9) + 1)")
            .resizable().scaledToFill().frame(width: size, height: size)
            .clipShape(Circle()).opacity(folded ? 0.4 : 1)
            .overlay(Circle().strokeBorder(allIn ? HandStyle.red : hero ? HandStyle.ink : HandStyle.line,
                                          style: StrokeStyle(lineWidth: hero || allIn ? 2 : 1, dash: folded ? [3, 2] : [])))
            .accessibilityHidden(true)
    }
}

extension PokerCard {
    var display: String {
        let rankLabel = [11: "J", 12: "Q", 13: "K", 14: "A"][rank] ?? String(rank)
        let suitLabel: String
        switch suit { case .clubs: suitLabel = "♣"; case .diamonds: suitLabel = "♦"; case .hearts: suitLabel = "♥"; case .spades: suitLabel = "♠" }
        return rankLabel + suitLabel
    }
    var analysisIndex: Int {
        let s: Int
        switch suit { case .clubs: s = 0; case .diamonds: s = 1; case .hearts: s = 2; case .spades: s = 3 }
        return (rank - 2) * 4 + s
    }
}

extension HandStreet {
    var label: String {
        switch self { case .preflop: "Preflop"; case .flop: "Flop"; case .turn: "Turn"; case .river: "River" }
    }
}

extension HandEventKind {
    var label: String {
        switch self {
        case .smallBlind: "SB"
        case .bigBlind: "BB"
        case .ante: "ANTE"
        case .deadBlind: "补盲 · 入池"
        case .liveBlind: "补盲 · 本街"
        case .fold: "FOLD"
        case .check: "CHECK"
        case .call: "CALL"
        case .bet: "BET"
        case .raiseTo: "RAISE TO"
        case .allIn: "ALL-IN TO"
        case .deal: "DEAL"
        }
    }
}
