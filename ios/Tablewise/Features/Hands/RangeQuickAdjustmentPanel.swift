import SwiftUI

/// No placeholder controls: only installed, approved and currently applicable operations appear.
struct RangeQuickAdjustmentPanel: View {
    let plan: RangePlan
    let hand: HandRecord
    let blockers: Set<Int>
    let plans: [RangePlan]
    let savedPlans: [RangePlan]
    let temporaryPlanIDs: Set<UUID>
    let apply: (RangeQuickAdjustmentPreview) -> Void
    @State private var preview: RangeQuickAdjustmentPreview?
    private var available: [RangeQuickAdjustmentPreview] {
        RangeCatalogRepository.bundled.quickPreviews(plan: plan, hand: hand, blockers: blockers,
            plans: plans, savedPlans: savedPlans, temporaryPlanIDs: temporaryPlanIDs)
    }
    var body: some View {
        if !available.isEmpty {
            DisclosureGroup("审核语义规则 · 调整我的假设") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(available) { item in Button(item.title) { preview = item } }
                }.padding(.top, 8)
            }.font(.subheadline).handPanel()
            .sheet(item: $preview) { item in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(item.explanation)
                            Text(item.limitations).foregroundStyle(HandStyle.muted)
                            Text("规则来源：\(item.sourceName) · \(item.reference.packageVersion)\n审核：\(item.reviewer) · \(item.reference.reviewId)")
                                .font(.caption)
                            Text("\(item.changes.count) 个具体组合 · 阻断跳过 \(item.blockedCount) 个")
                            Text(String(format: "加权组合变化 %+.2f · 非权益变化", item.weightedDelta))
                            ForEach(item.changes, id: \.index) { change in
                                HStack {
                                    Text(RangePlan.combinations[change.index].cards.map(\.label).joined())
                                    Spacer()
                                    Text(weight(change.before) + " → " + weight(change.after)).monospacedDigit()
                                }
                            }
                            Text("应用只修改当前用户假设。规则已审核不表示你的范围或行动频率已审核；可撤销，保存后保留来源记录。")
                                .font(.caption).foregroundStyle(HandStyle.muted)
                        }.padding()
                    }
                    .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { preview = nil } }
                        ToolbarItem(placement: .confirmationAction) { Button("应用") { apply(item); preview = nil } }
                    }
                }
            }
        }
    }
    private func weight(_ value: Double?) -> String { value.map { String(format: "%.2f%%", $0) } ?? "未知" }
}
