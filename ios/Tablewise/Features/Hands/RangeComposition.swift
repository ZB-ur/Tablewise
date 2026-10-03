import SwiftUI

/// Card-derived groups, not an action model or strategic recommendation.
struct RangeComposition {
    struct Group: Identifiable {
        let id: String
        let title: String
        let indices: [Int]
    }
    let made: [Group]
    let draws: [Group]

    static func build(board: [Int], blockers: Set<Int>) -> Self {
        guard [3, 4, 5].contains(board.count), Set(board).count == board.count else { return .init(made: [], draws: []) }
        var made: [Int: [Int]] = [:]
        var draws: [Int: [Int]] = [:]
        for (index, combo) in RangePlan.combinations.enumerated() where !combo.blocked(by: blockers) {
            let cards = board + [combo.first, combo.second]
            guard let value = try? PokerEvaluator.evaluate(cards) else { continue }
            made[value.category.rawValue, default: []].append(index)
            guard board.count < 5 else { continue }
            let ranks = Set(cards.map { $0 / 4 + 2 })
            let runs = (6...14).map { high in Set((high - 4)...high) } + [Set([14, 2, 3, 4, 5])]
            let hasStraight = runs.contains { $0.isSubset(of: ranks) }
            let live = Set(cards).union(blockers)
            let straightDraw = !hasStraight && runs.contains { run in
                let missing = run.subtracting(ranks)
                guard missing.count == 1, let rank = missing.first else { return false }
                return (0..<4).contains { !live.contains((rank - 2) * 4 + $0) }
            }
            let flushDraw = (0..<4).contains { suit in
                cards.filter { $0 % 4 == suit }.count == 4 && (0..<52).contains { $0 % 4 == suit && !live.contains($0) }
            }
            let bucket = (straightDraw ? 2 : 0) + (flushDraw ? 1 : 0)
            draws[bucket, default: []].append(index)
        }
        let madeGroups = PokerHandCategory.allCases.reversed().compactMap { category -> Group? in
            guard let indices = made[category.rawValue] else { return nil }
            return .init(id: "made-\(category.rawValue)", title: category.title, indices: indices)
        }
        let titles = ["无上述一张改善听牌", "仅同花听牌", "仅顺子听牌", "同花＋顺子双听牌"]
        let drawGroups = (0...3).reversed().compactMap { key -> Group? in
            guard let indices = draws[key] else { return nil }
            return .init(id: "draw-\(key)", title: titles[key], indices: indices)
        }
        return .init(made: madeGroups, draws: drawGroups)
    }
}

struct RangeCompositionSection: View {
    let board: [Int]
    let blockers: Set<Int>
    let weights: [Double?]?
    let onAssign: ([Int], Double, String) -> Void
    @State private var composition = RangeComposition(made: [], draws: [])
    private var context: String { "\(board)|\(blockers.sorted())" }
    var body: some View {
        DisclosureGroup("范围构成与按类调整") {
            VStack(alignment: .leading, spacing: 10) {
                if composition.made.isEmpty {
                    Text("翻牌前不构造成牌／听牌分类；可在矩阵选择具体类别。")
                } else {
                    Text("成牌 · 每个组合只计一次").font(.subheadline.weight(.semibold))
                    ForEach(composition.made) { group in row(group) }
                    if !composition.draws.isEmpty {
                        Divider()
                        Text("听牌 · 双听牌单独计数").font(.subheadline.weight(.semibold))
                        ForEach(composition.draws) { group in row(group) }
                    }
                    Text("成牌与听牌是两组分类，不能跨组相加。包括公共牌组成的牌力；听牌描述下一张成顺／成花事件，不代表胜率。")
                }
                Text("仅按当前牌张分类。选择类别及权重是你的手动假设，不是系统建议的行动频率。")
            }.font(.caption).foregroundStyle(HandStyle.muted).padding(.top, 10)
        }.font(.subheadline).handPanel()
            .task(id: context) { composition = RangeComposition.build(board: board, blockers: blockers) }
    }
    private func row(_ group: RangeComposition.Group) -> some View {
        let known = group.indices.compactMap { weights?[$0] }
        let sum = known.reduce(0,+) / 100
        return HStack {
            Text(group.title).foregroundStyle(HandStyle.ink)
            Spacer()
            Text(String(format: "%.2f", sum) + (known.count < group.indices.count ? " ＋未知" : ""))
                .monospacedDigit()
            Menu {
                ForEach([0,25,50,75,100], id: \.self) { weight in
                    Button("\(group.indices.count) 个组合设为 \(weight)%") {
                        onAssign(group.indices, Double(weight), "手动按类调整：\(group.title) → \(weight)%")
                    }
                }
            } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel("调整\(group.title)，\(group.indices.count) 个合法组合")
        }
    }
}
