import SwiftUI

/// Small rank diagrams share a five-card visual vocabulary while keeping each category distinct.
struct HandRankIcon: View {
    let category: PokerHandCategory
    private var groups: [Int] {
        switch category {
        case .highCard: [1,0,0,0,0]
        case .onePair: [1,1,0,0,0]
        case .twoPair: [1,1,2,2,0]
        case .threeOfAKind: [1,1,1,0,0]
        case .fullHouse: [1,1,1,2,2]
        case .fourOfAKind: [1,1,1,1,0]
        case .straight, .flush, .straightFlush: [1,1,1,1,1]
        }
    }
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5) { i in
                let step = category == .straight || category == .straightFlush
                RoundedRectangle(cornerRadius: 2)
                    .fill(groups[i] == 0 ? HandStyle.line : groups[i] == 2 ? HandStyle.gold : HandStyle.green)
                    .frame(width: 5, height: step ? CGFloat(9 + i * 3) : 17)
                    .overlay {
                        if category == .flush || category == .straightFlush {
                            Image(systemName: "suit.spade.fill").font(.system(size: 4)).foregroundStyle(.white)
                        }
                    }
            }
        }.frame(width: 35, height: 24).accessibilityHidden(true)
    }
}
