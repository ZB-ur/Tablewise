import SwiftUI

struct ReviewTotals {
    var hands = 0
    var confirmed = 0
    var pending = 0
    var withoutHero = 0
    var ambiguousHero = 0
    var chips = Decimal.zero
    var bigBlinds = 0.0

    init(hands records: [HandRecord]) {
        hands = records.count
        for hand in records {
            let heroes = hand.players.filter(\.isHero)
            if heroes.isEmpty { withoutHero += 1; continue }
            guard heroes.count == 1, let hero = heroes.first else {
                ambiguousHero += 1; continue
            }
            guard let settlement = hand.settlement, settlement.isCurrent(for: hand),
                  let final = settlement.finalBalances.first(where: { $0.playerID == hero.id })?.amount,
                  final.certainty == .exact, hero.startingStack.certainty == .exact,
                  let delta = final.subtracting(hero.startingStack).units,
                  let unit = hand.configuration.chipUnit.value, hand.configuration.bigBlind > 0 else {
                pending += 1; continue
            }
            confirmed += 1
            chips += Decimal(delta) * unit
            bigBlinds += Double(delta) / Double(hand.configuration.bigBlind)
        }
    }
    var countLabel: String {
        var label = "\(hands) 手 · 已确认 \(confirmed) · 待核对 \(pending)"
        if withoutHero > 0 { label += " · 未参与 / 未标记自己 \(withoutHero)" }
        if ambiguousHero > 0 { label += " · 自己标记冲突 \(ambiguousHero)" }
        return label
    }
    var chipLabel: String { confirmed == 0 ? "待结算" : NSDecimalNumber(decimal: chips).stringValue }
    var bbLabel: String { confirmed == 0 ? "待结算" : String(format: "%.2f BB", bigBlinds) }
}

struct ReviewStatisticsView: View {
    @ObservedObject var store: LocalStore
    var onOpenHand: (UUID) -> Void
    private var continuousIDs: Set<UUID> { Set(store.sessions.flatMap { $0.hands.map(\.handID) }) }
    private var continuous: [HandRecord] { store.hands.filter { continuousIDs.contains($0.id) } }
    private var independent: [HandRecord] { store.hands.filter { !continuousIDs.contains($0.id) } }
    var body: some View {
        List {
            totalsSection("连续场次 · 自己", records: continuous)
            totalsSection("精选独立复盘 · 自己", records: independent)
            Section {
                NavigationLink("书签、心得与待补信息") { ReviewQueueView(store: store, onOpenHand: onOpenHand) }
                LabeledContent("标记节点", value: "\(store.nodeAnnotations.filter(\.isBookmarked).count)")
                LabeledContent("待复盘", value: "\(store.nodeAnnotations.filter { $0.reviewStatus == "pending" }.count)")
                LabeledContent("已完成复盘", value: "\(store.nodeAnnotations.filter { $0.reviewStatus == "completed" }.count)")
            } header: { Text("学习记录") }
            if !store.sessions.isEmpty {
                Section("逐场次结果 · 自己") {
                    ForEach(store.sessions.sorted { $0.updatedAt > $1.updatedAt }) { session in
                        let ids = Set(session.hands.map(\.handID))
                        let total = ReviewTotals(hands: store.hands.filter { ids.contains($0.id) })
                        NavigationLink {
                            SessionDetailView(sessionID: session.id, store: store, onOpenHand: onOpenHand)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.title).font(.headline)
                                Text(total.countLabel)
                                    .font(.caption).foregroundStyle(HandStyle.muted)
                                Text("\(total.chipLabel) 筹码 · \(total.bbLabel)").font(.subheadline).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(HandStyle.canvas)
        .navigationTitle("统计").tint(HandStyle.green)
    }
    private func totalsSection(_ title: String, records: [HandRecord]) -> some View {
        let total = ReviewTotals(hands: records)
        return Section {
            LabeledContent("记录手数", value: "\(total.hands)")
            LabeledContent("自己已确认 / 待核对结算", value: "\(total.confirmed) / \(total.pending)")
            if total.withoutHero > 0 {
                LabeledContent("未参与 / 未标记自己", value: "\(total.withoutHero) 手")
            }
            if total.ambiguousHero > 0 {
                LabeledContent("自己标记冲突", value: "\(total.ambiguousHero) 手")
            }
            LabeledContent("牌局净额", value: total.chipLabel)
            LabeledContent("逐手 BB 净额", value: total.bbLabel)
        } header: { Text(title) } footer: {
            Text("只统计明确标为 You 且起始筹码、有效结算均确定的牌局。BB 按每手自身大盲换算；买入、补码、带走及校准另列，不计入扑克净额。精选复盘不并入连续场次玩家画像。")
        }
    }
}

struct ReviewMissingItem: Identifiable {
    var handID: UUID
    var eventID: UUID?
    var title: String
    var message: String
    var id: String { "\(handID)-\(eventID?.uuidString ?? "hand")-\(message)" }
    static func collect(_ hand: HandRecord) -> [Self] {
        let projection = HandReducer.project(hand)
        let eventIDs = Set(hand.events.map(\.id))
        var result = projection.issues.map { issue in
            Self(handID: hand.id, eventID: issue.eventID.flatMap { eventIDs.contains($0) ? $0 : nil }, title: hand.title, message: issue.message)
        }
        let hasCurrentSettlement = hand.settlement?.isCurrent(for: hand) == true
        let reachedEnd = projection.latest.handComplete || (projection.latest.street == .river && projection.latest.roundComplete)
        if !reachedEnd && !hasCurrentSettlement && projection.issues.isEmpty {
            result.append(.init(handID: hand.id, title: hand.title, message: "牌局尚未结束；后续事实待录入"))
        }
        if reachedEnd && !hasCurrentSettlement {
            result.append(.init(handID: hand.id, title: hand.title, message: "结果尚无有效结算"))
        }
        for player in hand.players where player.startingStack.certainty != .exact {
            result.append(.init(handID: hand.id, title: hand.title, message: "\(player.name) 起始筹码\(player.startingStack.certainty == .unknown ? "未知" : "为近似值")"))
        }
        return result
    }
}
