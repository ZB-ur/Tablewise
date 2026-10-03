import SwiftUI

struct AnalysisRangeSensitivityView: View {
    let hand: HandRecord
    let snapshot: HandSnapshot
    let subjectID: UUID
    let eventID: UUID?
    let after: Bool
    let reveal: Bool
    @ObservedObject var store: LocalStore
    var transientPlans: [String: RangePlan] = [:]
    @State private var targetID: UUID?
    @State private var planA: UUID?
    @State private var planB: UUID?
    @State private var outputA: AnalysisStampedEquity?
    @State private var outputB: AnalysisStampedEquity?

    private var targets: [HandPlayer] {
        hand.players.filter { player in
            snapshot.player(player.id)?.folded == false && !((reveal || player.id == subjectID) && player.holeCards.count == 2)
        }
    }
    private var plans: [RangePlan] {
        guard let eventID else { return [] }
        var values = store.rangePlans.filter {
            $0.handID == hand.id && $0.eventID == eventID && $0.subjectID == subjectID && $0.after == after && $0.reveal == reveal && $0.resolvedScope == .decision
        }
        for draft in transientPlans.values where draft.handID == hand.id && draft.eventID == eventID && draft.subjectID == subjectID && draft.after == after && draft.reveal == reveal && draft.resolvedScope == .decision {
            values.removeAll { $0.id == draft.id }; values.append(draft)
        }
        return values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private var available: [RangePlan] { plans.filter { $0.targetPlayerID == targetID } }
    private var draftOverrides: [UUID: RangePlan] {
        var result: [UUID: RangePlan] = [:]
        for draft in transientPlans.values where draft.handID == hand.id && draft.eventID == eventID && draft.subjectID == subjectID && draft.after == after && draft.reveal == reveal && draft.resolvedScope == .decision {
            result[draft.targetPlayerID] = draft
        }
        return result
    }
    private var dependencyPlans: [RangePlan] {
        RangePlanDependencies.environment(saved: store.rangePlans, temporary: Array(transientPlans.values))
    }
    private var inputStamp: String {
        let encodedPlans = RangeAnalysisContext.fingerprint(plans: store.rangePlans.filter { $0.handID == hand.id }) + "|" + RangeAnalysisContext.fingerprint(plans: dependencyPlans.filter { $0.handID == hand.id }) + "|temporary:" + transientPlans.values.map { $0.id.uuidString }.sorted().joined(separator: ",")
        // Actual node facts and all current hypotheses; independent of saved hand revision.
        let fact = "\(hand.id):\(hand.revision):\(eventID?.uuidString ?? "initial"):\(after):\(reveal):\(subjectID):\(targetID?.uuidString ?? "none")"
        return fact + ":" + encodedPlans
    }
    private func columnStamp(_ id: UUID?) -> String { inputStamp + ":" + (id?.uuidString ?? "none") }
    private func input(_ id: UUID?) -> Result<RangeAnalysisInput, Error> {
        do {
            guard let targetID, let id, let plan = available.first(where: { $0.id == id }) else {
                throw RangeAnalysisInputError.invalid("请明确选择待比较玩家与方案")
            }
            var overrides = draftOverrides; overrides[targetID] = plan
            return .success(try RangeAnalysisContext.build(hand: hand, snapshot: snapshot, subjectID: subjectID,
                                                           eventID: eventID, after: after, reveal: reveal,
                                                           plans: dependencyPlans, overrides: overrides, savedPlans: store.rangePlans, temporaryPlanIDs: Set(transientPlans.values.map(\.id))))
        } catch { return .failure(error) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("同节点 · 两方案比较").font(.headline)
                    Text("只替换一位玩家的明确范围方案；其他玩家、公共牌与主／边池资格保持相同。实际手牌在决策／揭牌边界内优先于范围。")
                        .font(.caption).foregroundStyle(HandStyle.muted)
                    if targets.isEmpty {
                        Text("当前可使用的手牌均已明确，没有待替换的范围对象。").font(.subheadline)
                    } else {
                        Picker("范围玩家", selection: $targetID) {
                            Text("请选择玩家").tag(Optional<UUID>.none)
                            ForEach(targets) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Text("未保存的当前临时假设也可参与比较；事实版本过期或权重未补齐会保留其失败原因。").font(.caption).foregroundStyle(HandStyle.muted)
                    }
                }.handPanel()
                if targetID != nil {
                    comparisonPicker("方案 A", selection: $planA)
                    AnalysisSensitivityColumn(title: "A", input: input(planA), stamp: columnStamp(planA), hand: hand,
                                              subjectID: subjectID) { outputA = $0 }
                    comparisonPicker("方案 B", selection: $planB)
                    if planA != nil && planA == planB {
                        Text("请选择两个不同方案。").font(.subheadline).foregroundStyle(HandStyle.gold).handPanel()
                    } else {
                        AnalysisSensitivityColumn(title: "B", input: input(planB), stamp: columnStamp(planB), hand: hand,
                                                  subjectID: subjectID) { outputB = $0 }
                    }
                    comparisonSummary
                }
            }.padding(16)
        }.background(HandStyle.canvas).foregroundStyle(HandStyle.ink)
            .navigationTitle("范围敏感性").navigationBarTitleDisplayMode(.inline)
            .onChange(of: targetID) { _, _ in planA = nil; planB = nil; outputA = nil; outputB = nil }
    }
    private func comparisonPicker(_ title: String, selection: Binding<UUID?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: selection) {
                Text("请选择方案").tag(Optional<UUID>.none)
                ForEach(available) { plan in Text("\(plan.name) · v\(plan.revision)").tag(Optional(plan.id)) }
            }
            if let id = selection.wrappedValue, let plan = available.first(where: { $0.id == id }) {
                ForEach(RangePlanDependencies.issues(for: plan, hand: hand, plans: dependencyPlans, savedPlans: store.rangePlans, temporaryPlanIDs: Set(transientPlans.values.map(\.id))), id: \.self) { issue in
                    Text("方案失效：" + issue).font(.caption).foregroundStyle(HandStyle.red)
                }
                Text("\(RangeCatalogRepository.bundled.sourceSummary(plan: plan, hand: hand)) · 事实 v\(plan.factRevision)\(plan.factRevision == hand.revision ? "" : " · 已过期")")
                    .font(.caption).foregroundStyle(HandStyle.muted)
            }
            if available.count < 2 { Text("本节点需至少两个同一玩家的方案；请先在范围工作台创建或保存。").font(.caption).foregroundStyle(HandStyle.muted) }
        }.handPanel()
    }
    @ViewBuilder private var comparisonSummary: some View {
        if planA != planB, let a = outputA, let b = outputB,
           a.stamp == columnStamp(planA), b.stamp == columnStamp(planB) {
            VStack(alignment: .leading, spacing: 9) {
                Text("已测试假设的差异").font(.headline)
                ForEach(a.result.pots, id: \.potID) { pot in
                    if let shareA = pot.shares.first(where: { $0.playerID == subjectID.uuidString }),
                       let shareB = b.result.pots.first(where: { $0.potID == pot.potID })?.shares.first(where: { $0.playerID == subjectID.uuidString }) {
                        Text("\(pot.potID) · B − A：\(String(format: "%+.2f", (shareB.equity - shareA.equity) * 100)) 个权益百分点")
                            .font(.subheadline)
                    }
                }
                if case .success(let current) = input(planA), let price = current.callPrice,
                   let qA = a.result.pots.first?.shares.first(where: { $0.playerID == subjectID.uuidString })?.equity,
                   let qB = b.result.pots.first?.shares.first(where: { $0.playerID == subjectID.uuidString })?.equity,
                   let evA = PokerMath.conditionalCallEV(equity: qA, price: price), let evB = PokerMath.conditionalCallEV(equity: qB, price: price) {
                    let same = (evA > 0 && evB > 0) || (evA < 0 && evB < 0) || (evA == 0 && evB == 0)
                    Text(same ? "这两个假设下，跟注相对弃牌的 EV 点估计方向一致。" : "这两个假设下，跟注相对弃牌的 EV 点估计方向不同，结论依赖范围假设。")
                        .font(.subheadline)
                }
                Text("仅比较这两套已计算假设，不代表覆盖所有合理范围。模拟差异含抽样误差；方向一致不等于统计显著或策略保证。")
                    .font(.caption).foregroundStyle(HandStyle.muted)
            }.handPanel()
        }
    }
}

private struct AnalysisStampedEquity {
    let stamp: String
    let result: EquityResult
}
private struct AnalysisSensitivityColumn: View {
    let title: String
    let input: Result<RangeAnalysisInput, Error>
    let stamp: String
    let hand: HandRecord
    let subjectID: UUID
    let onResult: (AnalysisStampedEquity?) -> Void
    @State private var completed: AnalysisStampedEquity?
    @State private var worker: Task<EquityResult, Error>?
    @State private var status = "待计算"
    @State private var running = false
    @State private var active = ""
    @State private var retry = 0
    private var taskID: String { stamp + ":\(retry)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("方案 \(title) · 实算").font(.headline)
            if case .success(let current) = input {
                ForEach(Array(current.assumptions.enumerated()), id: \.offset) { _, source in
                    Text(source).font(.caption).foregroundStyle(HandStyle.muted)
                }
            }
            if let completed, completed.stamp == stamp {
                ForEach(completed.result.pots, id: \.potID) { pot in
                    Text(pot.potID).font(.subheadline.weight(.semibold))
                    ForEach(pot.shares, id: \.playerID) { share in
                        HStack {
                            Text(hand.players.first { $0.id.uuidString == share.playerID }?.name ?? "玩家")
                            Spacer()
                            Text(String(format: completed.result.method == .exact ? "%.2f%%" : "≈%.1f%%", share.equity * 100)).monospacedDigit()
                        }.font(.subheadline)
                    }
                }
                Text("\(completed.result.method == .exact ? "精确枚举" : "模拟估计") · \(completed.result.samples) 样本／局面 · \(String(format: "%.2f", completed.result.elapsedSeconds)) 秒")
                    .font(.caption).foregroundStyle(HandStyle.muted)
                if completed.result.completion != .complete { Text("达到预算上限，以上只来自已完成样本。").font(.caption).foregroundStyle(HandStyle.gold) }
                if case .success(let current) = input {
                    if let price = current.callPrice,
                       let share = completed.result.pots.first?.shares.first(where: { $0.playerID == subjectID.uuidString }),
                       let ev = PokerMath.conditionalCallEV(equity: share.equity, price: price), let unit = hand.configuration.chipUnit.value {
                        Text("跟注 EV（相对弃牌）：\(ConditionalCallEVDisplay.text(ev * NSDecimalNumber(decimal: unit).doubleValue))")
                            .font(.subheadline.monospacedDigit())
                        Text("EV = 权益 × 跟后可争夺池 − 跟注成本").font(.caption)
                    }
                    Text(current.priceRestriction).font(.caption).foregroundStyle(HandStyle.muted)
                }
                Button("重新计算") { retry += 1 }.font(.caption)
            } else if active == taskID && running {
                HStack { ProgressView(); Text("计算中…"); Spacer(); Button("取消") { worker?.cancel() } }.font(.subheadline)
            } else {
                Text(active == taskID ? status : "输入已变化，旧结果失效").font(.subheadline).foregroundStyle(HandStyle.muted)
                Button("重试") { retry += 1 }.font(.caption)
            }
        }.handPanel()
        .task(id: taskID) { await calculate() }
        .onDisappear { worker?.cancel() }
    }
    private func calculate() async {
        let token = taskID
        worker?.cancel(); active = token; completed = nil; onResult(nil); running = false
        do {
            let input = try input.get()
            let request = input.request
            let task = Task.detached(priority: .userInitiated) { try EquityEngine.calculateSynchronously(request) }
            worker = task; running = true
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, active == token else { return }
            let output = AnalysisStampedEquity(stamp: stamp, result: result)
            completed = output; running = false; worker = nil; onResult(output)
        } catch {
            guard !Task.isCancelled, active == token else { return }
            status = error is CancellationError ? "计算已取消" : error.localizedDescription
            running = false; worker = nil
        }
    }
}
