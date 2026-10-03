import SwiftUI

/// Describes the selected prefix's contributions, never a future settlement.
struct NodePotBreakdown: View {
    let hand: HandRecord
    let snapshot: HandSnapshot
    let eventID: UUID?
    let after: Bool
    let units: StorePreferences.Units
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("主池、边池与未匹配投入", isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let structure = try? AnalysisNodePots.build(hand: hand, snapshot: snapshot, eventID: eventID, after: after) {
                        if structure.layers.isEmpty {
                            Text("当前尚无已匹配底池").foregroundStyle(HandStyle.muted)
                        }
                        ForEach(Array(structure.layers.enumerated()), id: \.offset) { index, layer in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(index == 0 ? "主池" : "边池 \(index)").fontWeight(.semibold)
                                    Spacer()
                                    Text(amount(layer.units)).monospacedDigit()
                                }
                                Text("当前争池：" + layer.eligibleIDs.compactMap { id in
                                    hand.players.first { $0.id == id }?.name
                                }.joined(separator: "、"))
                                .foregroundStyle(HandStyle.muted)
                            }
                        }
                        if structure.refundUnits > 0 {
                            HStack {
                                Text("未匹配投入")
                                Spacer()
                                Text(amount(structure.refundUnits)).monospacedDigit()
                            }
                            Text("尚未计入可匹配池；这不是已执行退款。")
                                .foregroundStyle(HandStyle.muted)
                        }
                        Text("按当前节点已发生的投入分层，后续跟注或弃牌可能改变金额与资格。")
                            .foregroundStyle(HandStyle.muted)
                    } else {
                        Text("底池分层待核对：当前记录有缺项、近似金额或冲突。")
                            .foregroundStyle(HandStyle.gold)
                    }
                }.font(.caption).padding(.top, 6)
            }
        }.font(.caption.weight(.medium)).tint(HandStyle.ink)
    }

    private func amount(_ value: Int64) -> String {
        guard units == .bigBlinds, hand.configuration.bigBlind > 0 else {
            return hand.configuration.chipUnit.format(units: value)
        }
        return String(format: "%.2f BB", Double(value) / Double(hand.configuration.bigBlind))
    }
}
