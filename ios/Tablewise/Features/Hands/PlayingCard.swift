import SwiftUI

private enum PlayingCardPalette {
    static let paper = Color.white
    static let ink = Color(red: 0.20, green: 0.22, blue: 0.21)
    static let line = Color(red: 0.89, green: 0.89, blue: 0.87)
    static let green = Color(red: 0.23, green: 0.47, blue: 0.37)
    static let blue = Color(red: 0.27, green: 0.43, blue: 0.59)
    static let red = Color(red: 0.68, green: 0.32, blue: 0.27)
}

struct PlayingCard: View {
    let value: String
    var small = false
    var body: some View {
        let rank = String(value.dropLast()), suit = String(value.suffix(1))
        VStack(spacing: 0) {
            Text(rank).font(.system(size: small ? 15 : 21, weight: .bold, design: .serif))
            Text(suit).font(.system(size: small ? 10 : 12, weight: .semibold))
        }
        .foregroundStyle(suit == "♥" ? PlayingCardPalette.red : suit == "♦" ? PlayingCardPalette.blue : suit == "♣" ? PlayingCardPalette.green : PlayingCardPalette.ink)
        .frame(width: small ? 28 : 35, height: small ? 38 : 46)
        .background(PlayingCardPalette.paper, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(PlayingCardPalette.line))
        .accessibilityLabel("\(rank) \(suit)")
    }
}

