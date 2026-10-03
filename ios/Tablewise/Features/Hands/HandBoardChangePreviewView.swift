import SwiftUI

/// A detached hand edit. Previewing never changes the store or the current node selection.
struct HandBoardChangePreview {
    let original: HandRecord
    let proposed: HandRecord
    let event: HandEvent
    let current: HandProjection
    let replacement: HandProjection

    var proposedEvent: HandEvent? { proposed.events.first { $0.id == event.id } }
    var isDeletion: Bool { proposedEvent == nil }
    var operationTitle: String { isDeletion ? "删除" : "更正" }

    init(original: HandRecord, event: HandEvent, proposed candidate: HandRecord? = nil, revisionHighWatermark: Int? = nil) {
        self.original = original
        self.event = event
        var proposed = candidate ?? original
        if let revisionHighWatermark { proposed.retainRevisionCeiling(revisionHighWatermark) }
        if candidate == nil { proposed.remove(eventID: event.id) }
        self.proposed = proposed
        current = HandReducer.project(original)
        replacement = HandReducer.project(proposed)
    }

    /// Full-record comparison also protects notes and edits made while this sheet is open.
    func isCurrent(for hand: HandRecord) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(original) == encoder.encode(hand)
    }

    var retainedNodes: [HandNode] {
        let index = original.events.firstIndex { $0.id == event.id } ?? original.events.endIndex
        let affectedIDs = Set(original.events.enumerated().compactMap { offset, other in
            other.id != event.id && (offset > index || other.street.order >= event.street.order) ? other.id : nil
        })
        return replacement.nodes.filter { affectedIDs.contains($0.id) }
    }

    var otherIssues: [HandIssue] {
        let retainedIDs = Set(retainedNodes.map(\.id))
        return replacement.issues.filter { issue in
            issue.eventID.map { !retainedIDs.contains($0) } ?? true
        }
    }
}

struct HandBoardChangePreviewView: View {
    let preview: HandBoardChangePreview
    var onClose: (() -> Void)? = nil
    let onConfirm: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var committed = false

    private var unit: ChipUnit { preview.original.configuration.chipUnit }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Button("取消\(preview.operationTitle)") { close() }
                        .frame(minWidth: 72, minHeight: 44)
                    Spacer()
                    Text("\(preview.operationTitle)公共牌预览").font(.headline)
                    Spacer()
                    Button("确认\(preview.operationTitle)", role: preview.isDeletion ? .destructive : nil) { commit() }
                        .fontWeight(.semibold).frame(minWidth: 72, minHeight: 44)
                        .disabled(committed)
                }.buttonStyle(.plain).padding(.horizontal, 16)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HandBoardChangeImpactContent(preview: preview)
                        settlementImpact
                        Text("笔记和书签仍关联原节点，\(preview.operationTitle)可撤销。")
                            .font(.footnote).foregroundStyle(HandStyle.muted)
                    }.padding(16)
                }.background(HandStyle.canvas)
            }
            .foregroundStyle(HandStyle.ink)
            .toolbar(.hidden, for: .navigationBar)
            .alert("\(preview.operationTitle)未保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    @ViewBuilder private var settlementImpact: some View {
        if let settlement = preview.original.settlement, settlement.isCurrent(for: preview.original) {
            VStack(alignment: .leading, spacing: 12) {
                Text("已确认结算余额").font(.headline)
                ForEach(settlement.finalBalances) { balance in
                    LabeledContent(preview.original.players.first { $0.id == balance.playerID }?.name ?? "未知玩家",
                                   value: "\(unit.format(balance.amount)) → 待核对")
                        .font(.subheadline).monospacedDigit()
                }
                Text("\(preview.operationTitle)会使原结算失效；保留原结果，重新核对后才能确认新余额。")
                    .font(.footnote).foregroundStyle(HandStyle.gold)
            }.frame(maxWidth: .infinity, alignment: .leading).handPanel()
        }
    }

    private func commit() {
        guard !committed else { return }
        do {
            try onConfirm()
            committed = true
            close()
        } catch { self.error = error.localizedDescription }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}

/// The shared display has no presentation or commit controls; its host owns the transaction.
struct HandBoardChangeImpactContent: View {
    let preview: HandBoardChangePreview
    private var unit: ChipUnit { preview.original.configuration.chipUnit }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            changedCards
            financialImpact
            retainedNodes
            if !preview.otherIssues.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("其他待核对").font(.headline)
                    ForEach(preview.otherIssues) { issue in
                        Label(issue.message, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(HandStyle.gold)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).handPanel()
            }
        }.foregroundStyle(HandStyle.ink)
    }

    private var changedCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("将\(preview.operationTitle) · \(preview.event.street.title)公共牌").font(.headline)
            if let proposedEvent = preview.proposedEvent {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        cards(preview.event.cards)
                        Image(systemName: "arrow.right").foregroundStyle(HandStyle.muted)
                            .accessibilityLabel("更正为")
                        cards(proposedEvent.cards)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前").font(.caption).foregroundStyle(HandStyle.muted)
                        cards(preview.event.cards)
                        Text("↓ 更正为").font(.caption).foregroundStyle(HandStyle.muted)
                        cards(proposedEvent.cards)
                    }
                }
            } else {
                cards(preview.event.cards)
            }
            Text("本页仅预览。取消返回原上下文，确认后才保存。")
                .font(.footnote).foregroundStyle(HandStyle.muted)
            Text("确认后原分析与范围方案需要按新事实版本重新核对。")
                .font(.footnote).foregroundStyle(HandStyle.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).handPanel()
    }

    private func cards(_ values: [PokerCard]) -> some View {
        HStack(spacing: 6) { ForEach(values) { card in PlayingCard(value: card.display) } }
    }

    private var financialImpact: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("底池与后手").font(.headline)
            HStack {
                Text("整手最新记录").foregroundStyle(HandStyle.muted)
                Spacer()
                Text("当前 → \(preview.operationTitle)后").fontWeight(.semibold)
            }.font(.caption)
            comparison("底池", previous: amount(preview.current.latest.pot, snapshot: preview.current.latest),
                       proposed: amount(preview.replacement.latest.pot, snapshot: preview.replacement.latest))
            ForEach(HandReducer.orderedPlayers(preview.original)) { player in
                comparison(player.name,
                           previous: amount(preview.current.latest.player(player.id)?.remaining ?? .unknown, snapshot: preview.current.latest),
                           proposed: amount(preview.replacement.latest.player(player.id)?.remaining ?? .unknown, snapshot: preview.replacement.latest))
            }
            Text("缺项或冲突之后的底池与后手待核对，未知金额不按 0 处理。")
                .font(.footnote).foregroundStyle(HandStyle.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).handPanel()
    }

    private var retainedNodes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("受影响节点 · 保留 \(preview.retainedNodes.count) 个").font(.headline)
            if preview.retainedNodes.isEmpty {
                Text("没有后续节点需要核对。").font(.subheadline).foregroundStyle(HandStyle.muted)
            }
            ForEach(preview.retainedNodes) { node in
                VStack(alignment: .leading, spacing: 6) {
                    let number = (preview.original.events.firstIndex { $0.id == node.id } ?? 0) + 1
                    Text("第\(number)步 · \(node.event.street.label) · \(eventLabel(node.event))")
                        .font(.subheadline.weight(.semibold))
                    if node.event.kind == .deal {
                        HStack(spacing: 4) { ForEach(node.event.cards) { card in PlayingCard(value: card.display, small: true) } }
                    }
                    Label(node.issues.isEmpty ? "原节点保留" : "原节点保留 · 待核对",
                          systemImage: node.issues.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(node.issues.isEmpty ? HandStyle.green : HandStyle.gold)
                    ForEach(node.issues) { issue in
                        Text(issue.message).font(.footnote).foregroundStyle(HandStyle.gold)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("后续行动和已知牌张不清空，身份与先后顺序保留。")
                .font(.footnote).foregroundStyle(HandStyle.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).handPanel()
    }

    private func comparison(_ label: String, previous: String, proposed: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text("\(previous) → \(proposed)").monospacedDigit()
        }.font(.subheadline)
    }

    private func amount(_ amount: ChipAmount, snapshot: HandSnapshot) -> String {
        snapshot.blocked ? "待核对" : unit.format(amount)
    }

    private func eventLabel(_ event: HandEvent) -> String {
        let name = preview.original.players.first { $0.id == event.playerID }?.name ?? "全桌"
        return "\(name) · \(event.kind.title)" + (event.amount.map { " \(unit.format($0))" } ?? "")
    }
}
