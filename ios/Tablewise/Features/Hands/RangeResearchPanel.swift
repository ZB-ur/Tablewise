import SwiftUI

/// A separate research calculation: every participant uses an explicitly chosen full range.
/// Recorded actual hole cards remain facts, but are not inputs to this calculation.
struct RangeResearchPanel: View {
    let hand: HandRecord
    let eventID: UUID
    let snapshot: HandSnapshot
    let subjectID: UUID
    let after: Bool
    let reveal: Bool
    let plans: [RangePlan]
    let transientPlans: [String: RangePlan]
    @Binding var choices: [UUID: UUID]
    @Binding var expanded: Bool
    @State private var result: EquityResult?
    @State private var resultKey = ""
    @State private var message: String?
    @State private var worker: Task<EquityResult, Error>?
    @State private var running = false
    @State private var currentInputKey = ""
    @State private var inputGeneration: UUID?
    @State private var activeRunID: UUID?

    private var participants: [HandPlayer] { hand.players.filter { snapshot.player($0.id)?.folded == false } }
    private func candidates(_ id: UUID) -> [RangePlan] {
        var values = plans.filter { $0.matches(handID: hand.id, eventID: eventID, subjectID: subjectID, targetPlayerID: id, after: after, reveal: reveal, scope: .fullRangeResearch) }
        if let draft = transientPlans[RangePlan.contextKey(handID: hand.id, eventID: eventID, subjectID: subjectID, targetPlayerID: id, after: after, reveal: reveal, scope: .fullRangeResearch)] {
            values.removeAll { $0.id == draft.id }; values.insert(draft, at: 0)
        }
        return values
    }
    private var selected: [UUID: RangePlan] {
        var values: [UUID: RangePlan] = [:]
        for player in participants { if let plan = candidates(player.id).first(where: { $0.id == choices[player.id] }) { values[player.id] = plan } }
        return values
    }
    private var dependencyPlans: [RangePlan] {
        RangePlanDependencies.environment(saved: plans, temporary: Array(transientPlans.values))
    }
    private var fingerprint: String {
        let serialized = RangeAnalysisContext.fingerprint(plans: plans.filter { $0.handID == hand.id }) + "|" + RangeAnalysisContext.fingerprint(plans: dependencyPlans.filter { $0.handID == hand.id }) + "|temporary:" + transientPlans.values.map { $0.id.uuidString }.sorted().joined(separator: ",") + "|" + RangeAnalysisContext.fingerprint(plans: Array(selected.values))
        return "\(hand.id)|\(hand.revision)|\(eventID)|\(subjectID)|\(after)|\(reveal)|\(snapshot.board.map(\.id))|\(participants.map(\.id))|\(serialized)"
    }
    var body: some View {
        DisclosureGroup("完整范围对完整范围 · 独立研究", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("双方均用完整范围；不使用已录入的实际底牌，仅排除当前公共牌及组合间冲突。此结果不替代上方实际手牌分析。")
                    .font(.caption).foregroundStyle(HandStyle.muted)
                Text("先开启上方独立研究编辑，为每位玩家建立研究方案，再在此明确选择。")
                    .font(.caption).foregroundStyle(HandStyle.muted)
                ForEach(participants) { player in
                    Picker(player.name + "完整范围", selection: Binding(get: { choices[player.id] }, set: { choices[player.id] = $0 })) {
                        Text("明确选择方案").tag(nil as UUID?)
                        ForEach(candidates(player.id)) { plan in Text(plan.name).tag(Optional(plan.id)) }
                    }
                }
                if participants.count > 2 {
                    Text("当前为多人节点，需为全部未弃牌玩家指定完整范围；不静默移除其他玩家。")
                        .font(.caption).foregroundStyle(HandStyle.muted)
                }
                if running {
                    HStack { ProgressView("范围研究计算中"); Spacer(); Button("取消") { invalidateRun(message: "研究计算已取消，可重试") } }
                } else {
                    Button("计算所选完整范围") {
                        let generation = inputGeneration
                        Task { await calculate(generation: generation) }
                    }
                        .buttonStyle(.bordered).disabled(participants.count < 2 || selected.count != participants.count)
                }
                if resultKey == fingerprint, let result {
                    ForEach(result.pots, id: \.potID) { pot in
                        Text(pot.potID).font(.subheadline.weight(.semibold))
                        ForEach(pot.shares, id: \.playerID) { share in
                            HStack {
                                Text(participants.first { $0.id.uuidString == share.playerID }?.name ?? "玩家")
                                Spacer()
                                Text(String(format: result.method == .exact ? "%.2f%%" : "≈%.1f%%", share.equity * 100)).monospacedDigit()
                            }
                        }
                    }
                    Text("\(result.method == .exact ? "精确枚举" : "模拟估计") · \(result.samples) 个局面 · \(String(format: "%.2f", result.elapsedSeconds)) 秒\(result.completion == .complete ? "" : " · 达到计算预算")")
                        .font(.caption).foregroundStyle(HandStyle.muted)
                    Text("完整范围研究不输出当前具体手牌的条件 EV。")
                        .font(.caption).foregroundStyle(HandStyle.muted)
                }
                if let message { Text(message).font(.caption).foregroundStyle(HandStyle.gold) }
            }.padding(.top, 10)
        }.font(.subheadline).handPanel()
            .onAppear { currentInputKey = fingerprint; inputGeneration = UUID() }
            .onChange(of: fingerprint) { _, key in
                currentInputKey = key
                inputGeneration = UUID()
                invalidateRun(message: "输入变化，旧研究结果已失效")
            }
            .onDisappear {
                currentInputKey = ""
                inputGeneration = nil
                invalidateRun(message: nil)
            }
    }
    @MainActor private func invalidateRun(message newMessage: String?) {
        // Revoke ownership before cancellation can resume an old continuation.
        activeRunID = nil
        worker?.cancel(); worker = nil; running = false
        result = nil; resultKey = ""; message = newMessage
    }
    @MainActor private func ownsRun(_ id: UUID, key: String) -> Bool {
        activeRunID == id && currentInputKey == key
    }
    @MainActor private func calculate(generation: UUID?) async {
        let key = fingerprint
        // A queued button task may carry a View value from a superseded input or presentation.
        guard let generation, generation == inputGeneration, key == currentInputKey,
              selected.count == participants.count else { return }
        invalidateRun(message: nil)
        let runID = UUID()
        activeRunID = runID
        do {
            let input = try RangeAnalysisContext.build(hand: hand, snapshot: snapshot, subjectID: subjectID, eventID: eventID,
                                                       after: after, reveal: reveal, plans: dependencyPlans, overrides: selected, fullRanges: true, savedPlans: plans, temporaryPlanIDs: Set(transientPlans.values.map(\.id)))
            let request = input.request
            running = true
            let task = Task.detached(priority: .userInitiated) { try await EquityEngine.calculate(request) }
            worker = task
            let answer = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard ownsRun(runID, key: key) else { return }
            if task.isCancelled || Task.isCancelled { message = "研究计算已取消，可重试" }
            else { result = answer; resultKey = key }
        } catch is CancellationError {
            guard ownsRun(runID, key: key) else { return }
            message = "研究计算已取消，可重试"
        } catch {
            guard ownsRun(runID, key: key) else { return }
            message = error.localizedDescription
        }
        guard ownsRun(runID, key: key) else { return }
        running = false; worker = nil; activeRunID = nil
    }
}
