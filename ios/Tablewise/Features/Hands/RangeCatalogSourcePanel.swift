import SwiftUI

struct RangeCatalogSourcePanel: View {
    let query: RangeCatalogQuery
    let subjectID: UUID
    let reveal: Bool
    let scope: RangePlan.Scope
    let draft: RangePlan?
    let priors: [RangePlan]
    let dependencyPlans: [RangePlan]
    let savedPlans: [RangePlan]
    let temporaryPlanIDs: Set<UUID>
    let adopt: (RangePlan) -> Void
    @State private var priorID: UUID?
    @State private var updates: [RangeCatalogUpdate] = []
    @State private var updateMessage: String?
    private let repository = RangeCatalogRepository.bundled
    private var status: RangeCatalogMatchStatus { repository.match(query) }

    var body: some View {
        DisclosureGroup("范围来源 · \(status.title)") {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(query.hand.players.count) 人 · \(HandReducer.positions(in: query.hand)[query.targetPlayerID] ?? "位置待核对") · \(query.snapshot?.street.title ?? "节点待核对") · 事实 v\(query.hand.revision)")
                if repository.installed.isEmpty {
                    Text("尚未安装可用的审核范围参考。当前节点待覆盖，你的手工假设保持原样。")
                }
                ForEach(status.missing, id: \.self) { Text("条件缺项：" + $0) }
                if !status.mismatches.isEmpty {
                    Text("已有参考未覆盖这些条件：" + status.mismatches.joined(separator: "、"))
                }
                if status.matches.isEmpty && !repository.installed.isEmpty && status.missing.isEmpty {
                    Text("此节点尚无完整匹配，不会默认收紧范围或补造未知权重。")
                }
                ForEach(Array(status.matches.enumerated()), id: \.offset) { _, match in
                    matchCard(match)
                }
                if let draft {
                    let issues = RangePlanDependencies.issues(for: draft, hand: query.hand, plans: dependencyPlans, savedPlans: savedPlans, temporaryPlanIDs: temporaryPlanIDs)
                    ForEach(issues, id: \.self) { Text("方案失效：" + $0).foregroundStyle(HandStyle.red) }
                    if !issues.isEmpty && query.after {
                        Text("重新生成：在下方选择当前行动前先验，检查已审核模型，再明确采用为新假设。已保存的方案保留；未保存的手改需先保存，或在采用时明确放弃。没有模型覆盖时等待审核来源。")
                    }
                }
                if query.after { updateControls }
                else { Text("行动更新需在行动后明确选择同一节点的行动前先验；只使用覆盖实际行动的审核行为模型。") }
                if let updateMessage { Text(updateMessage).foregroundStyle(HandStyle.gold) }
                if let draft {
                    Divider()
                    Text(repository.sourceSummary(plan: draft, hand: query.hand))
                    if let reference = draft.catalogReference { referenceDetails(reference) }
                }
                Text("采用参考只建立未保存的临时假设；需点击“保存方案”才会持久保存。采用前可先保存当前手改；未保存稿的替换需明确确认。阻断牌张另行处理。")
                if !status.installationIssues.isEmpty {
                    DisclosureGroup("来源可用性详情") {
                        ForEach(status.installationIssues, id: \.self) { Text($0).font(.caption2) }
                    }
                }
            }.font(.caption).foregroundStyle(HandStyle.muted).padding(.top, 8)
        }.font(.subheadline).handPanel()
        .onChange(of: priorID) { _, _ in updates = []; updateMessage = nil }
        .onChange(of: temporaryPlanIDs) { _, _ in updates = []; updateMessage = nil }
        .onChange(of: savedPlans) { _, _ in updates = []; updateMessage = nil }
        .onChange(of: dependencyPlans) { _, _ in updates = []; updateMessage = nil }
    }

    private func matchCard(_ match: RangeCatalogMatch) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(match.sourceName).font(.subheadline.weight(.semibold)).foregroundStyle(HandStyle.ink)
            Text(match.origin == "teaching" ? "已审核教学简化 · 不作策略判错或均衡结论" : "已审核来源 · 匹配此节点的明确条件")
            Text(match.conditions)
            DisclosureGroup("来源证据与版本") {
                Text("原始来源：" + match.sourceURI).textSelection(.enabled)
                Text("来源版本：" + match.sourceRevision)
                referenceDetails(match.reference)
            }
            Button("采用 \(match.sourceName) 为临时假设") {
                do { adopt(try repository.hypothesis(from: match, query: query, subjectID: subjectID, reveal: reveal, scope: scope)); updateMessage = nil }
                catch { updateMessage = error.localizedDescription }
            }.buttonStyle(.bordered).foregroundStyle(HandStyle.ink)
        }.padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
    }

    private var updateControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("行动前 → 行动后 · 固定行为假设").font(.subheadline.weight(.semibold))
            Text("采用你明确选择的先验 w，按审核行动概率 q 生成 w × q；不全局归一化，不重新求解均衡，未知先验仍未知。")
            if priors.isEmpty { Text("此节点尚无当前事实版本的行动前方案。请先在行动前建立或选择先验。") }
            else {
                Picker("行动更新先验", selection: $priorID) {
                    Text("请选择行动前方案").tag(Optional<UUID>.none)
                    ForEach(priors) { prior in
                        Text("\(prior.name) · v\(prior.revision)\(savedPlans.contains(prior) ? " · 已保存" : " · 临时")").tag(Optional(prior.id))
                    }
                }
                Button("检查已审核行动模型") { prepareUpdates() }
                    .disabled(priorID == nil).buttonStyle(.bordered)
            }
            ForEach(Array(updates.enumerated()), id: \.offset) { _, update in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(update.sourceName) · \(update.actionLabel) · \(update.changedCombinationCount) 个组合变化")
                    Button("采用 \(update.actionLabel) 更新为临时假设") { adopt(update.plan) }
                        .buttonStyle(.bordered).foregroundStyle(HandStyle.ink)
                }
            }
        }
    }
    private func prepareUpdates() {
        guard let prior = priors.first(where: { $0.id == priorID }) else { return }
        do {
            updates = try repository.updates(prior: prior, after: query, plans: dependencyPlans, savedPlans: savedPlans, temporaryPlanIDs: temporaryPlanIDs,
                origin: savedPlans.contains(prior) ? .saved : .temporary)
            updateMessage = updates.isEmpty ? "此行动尚无已审核模型覆盖，保留先验，不自动窄化。" : "原行动前方案保留；请明确采用其中一个模型生成新的行动后假设。"
        } catch { updates = []; updateMessage = error.localizedDescription }
    }
    private func referenceDetails(_ reference: RangeCatalogReference) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("包：\(reference.packageId) · \(reference.packageVersion)")
            Text("节点：\(reference.nodeId) · 审核：\(reference.reviewId)")
            Text("内容指纹：" + reference.contentHash).textSelection(.enabled)
            if let action = reference.actionId {
                Text("模型行动：" + action + " · 前序节点：" + (reference.parentNodeId ?? "缺失"))
                Text("先验指纹：" + (reference.parentWeightsHash ?? "缺失")).textSelection(.enabled)
            }
        }.font(.caption2)
    }
}
