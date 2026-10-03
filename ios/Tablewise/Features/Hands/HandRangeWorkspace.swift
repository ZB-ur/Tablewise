import SwiftUI
import UIKit

/// Presentation identity excludes the fact revision so fact edits retain a visibly stale draft.
/// Range-player/scope changes remain separate RangePlan contexts inside this workspace.
struct HandRangeWorkspaceIdentity: Hashable {
    let handID: UUID
    let eventID: UUID
    let subjectID: UUID
    let after: Bool
    let reveal: Bool
}

/// In-memory UI state only; named plans and analysis inputs still use RangePlan/transientPlans.
struct HandRangeWorkspaceState {
    var loadedContext: String?
    var targetID: UUID?
    var draft: RangePlan?
    var selected: String?
    var comparisonID: UUID?
    var edits: [[Double?]] = []
    var error: String?
    var onlyChanges = false
    var changeReason = ""
    var researchEditing = false
    var pendingCatalogPlan: RangePlan?
    var pendingCatalogDraft: RangePlan?
    var showCatalogReplacement = false
    var researchChoices: [UUID: UUID] = [:]
    var researchExpanded = false
}

/// Inline user-authored ranges. Never seeds a strategy or reads board cards beyond the snapshot.
struct HandRangeWorkspace: View {
    let hand: HandRecord
    let eventID: UUID
    let snapshot: HandSnapshot
    let subjectID: UUID
    let after: Bool
    let reveal: Bool
    @ObservedObject var store: LocalStore
    @Binding var transientPlans: [String: RangePlan]
    @Binding var state: HandRangeWorkspaceState

    // The hand workspace owns these values across detail/editor presentation changes.
    private var targetID: UUID? { get { state.targetID } nonmutating set { state.targetID = newValue } }
    private var draft: RangePlan? { get { state.draft } nonmutating set { state.draft = newValue } }
    private var selected: String? { get { state.selected } nonmutating set { state.selected = newValue } }
    private var comparisonID: UUID? { get { state.comparisonID } nonmutating set { state.comparisonID = newValue } }
    private var edits: [[Double?]] { get { state.edits } nonmutating set { state.edits = newValue } }
    private var error: String? { get { state.error } nonmutating set { state.error = newValue } }
    private var onlyChanges: Bool { get { state.onlyChanges } nonmutating set { state.onlyChanges = newValue } }
    private var changeReason: String { get { state.changeReason } nonmutating set { state.changeReason = newValue } }
    private var researchEditing: Bool { get { state.researchEditing } nonmutating set { state.researchEditing = newValue } }
    private var pendingCatalogPlan: RangePlan? { get { state.pendingCatalogPlan } nonmutating set { state.pendingCatalogPlan = newValue } }
    private var pendingCatalogDraft: RangePlan? { get { state.pendingCatalogDraft } nonmutating set { state.pendingCatalogDraft = newValue } }
    private var showCatalogReplacement: Bool { get { state.showCatalogReplacement } nonmutating set { state.showCatalogReplacement = newValue } }
    private var scope: RangePlan.Scope { researchEditing ? .fullRangeResearch : .decision }

    private var target: UUID { targetID ?? hand.players.first(where: { $0.id != subjectID && snapshot.player($0.id)?.folded == false })?.id ?? subjectID }
    private var context: String { RangePlan.contextKey(handID: hand.id, eventID: eventID, subjectID: subjectID, targetPlayerID: target, after: after, reveal: reveal, scope: scope) }
    private var plans: [RangePlan] {
        store.rangePlans.filter { $0.matches(handID: hand.id, eventID: eventID, subjectID: subjectID, targetPlayerID: target, after: after, reveal: reveal, scope: scope) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private var comparisons: [RangePlan] {
        store.rangePlans.filter { $0.handID == hand.id && $0.eventID == eventID && $0.subjectID == subjectID && $0.targetPlayerID == target && $0.reveal == reveal && $0.resolvedScope == scope && $0.id != draft?.id }
    }
    private var dependencyPlans: [RangePlan] {
        RangePlanDependencies.environment(saved: store.rangePlans, temporary: Array(transientPlans.values))
    }
    private var comparison: RangePlan? { comparisons.first { $0.id == comparisonID } }
    private var blockers: Set<Int> {
        var cards = snapshot.board
        if !researchEditing {
            for player in hand.players where player.id != target && (reveal || player.id == subjectID) { cards += player.holeCards }
        }
        return Set(cards.map(\.analysisIndex))
    }
    private var legal: [Int] { RangePlan.combinations.indices.filter { !RangePlan.combinations[$0].blocked(by: blockers) } }
    private var unknown: Int { legal.filter { draft?.weights[$0] == nil }.count }
    private var total: Double { legal.reduce(0) { $0 + (draft?.weights[$1] ?? 0) / 100 } }
    private var dirty: Bool { draft.map { current in plans.first { $0.id == current.id } != current } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            planSelector
            matrix
            summary.id("range-details")
            if let selected { combinationDetails(selected) }
            planControls
            RangeCompositionSection(board: snapshot.board.map(\.analysisIndex), blockers: blockers, weights: draft?.weights) { indices, weight, reason in
                assign(indices, weight, reason: reason)
            }
            if let draft {
                RangeQuickAdjustmentPanel(plan: draft, hand: hand, blockers: blockers, plans: dependencyPlans, savedPlans: store.rangePlans,
                    temporaryPlanIDs: Set(transientPlans.values.map(\.id))) { preview in
                    do {
                        guard let current = self.draft else { return }
                        self.draft = try RangeCatalogRepository.bundled.applyQuickPreview(preview, plan: current, hand: hand, blockers: blockers,
                            plans: dependencyPlans, savedPlans: store.rangePlans, temporaryPlanIDs: Set(transientPlans.values.map(\.id)))
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
            learningPanel
            RangeResearchPanel(hand: hand, eventID: eventID, snapshot: snapshot, subjectID: subjectID, after: after, reveal: reveal, plans: store.rangePlans, transientPlans: transientPlans, choices: $state.researchChoices, expanded: $state.researchExpanded)
            sourcePanel
            if let error { Text(error).font(.caption).foregroundStyle(HandStyle.red) }
        }
        .foregroundStyle(HandStyle.ink)
        .onAppear { loadContextIfNeeded() }
        .onChange(of: context) { _, _ in loadContextIfNeeded() }
        .onChange(of: draft) { _, value in
            if let value, transientPlans[value.contextKey] != value { transientPlans[value.contextKey] = value }
        }
        .alert("替换当前未保存的假设？", isPresented: $state.showCatalogReplacement, presenting: pendingCatalogPlan) { plan in
            Button("保留当前稿，先保存", role: .cancel) { clearCatalogReplacement() }
            Button("放弃未保存修改并采用", role: .destructive) { confirmCatalogReplacement(plan) }
        } message: { _ in
            Text("采用新假设将丢弃当前稿的未保存权重、判断和修改记录。要保留，请取消并点击“保存方案”或“另存方案”，再重新采用。已保存的方案不会被覆盖。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("完整范围").font(.headline)
                Spacer()
                Picker("范围玩家", selection: Binding(get: { target }, set: { targetID = $0 })) {
                    ForEach(hand.players) { Text($0.name).tag($0.id) }
                }.tint(HandStyle.ink)
            }
            Text("分析：\(name(subjectID)) · \(after ? "行动后" : "行动前") · \(reveal ? "揭牌" : "决策")")
                .font(.caption).foregroundStyle(HandStyle.muted)
            Toggle("独立完整范围研究编辑", isOn: $state.researchEditing).font(.caption)
            if researchEditing {
                Text("仅公共牌阻断 · 独立研究方案不会用于实际手牌决策。")
                    .font(.caption).foregroundStyle(HandStyle.gold)
            } else if target == subjectID {
                Text("已录入的实际手牌与完整范围分别保存。")
                    .font(.caption).foregroundStyle(HandStyle.muted)
            }
            if let draft, draft.factRevision != hand.revision {
                Text("事实已变更 · 此方案基于 v\(draft.factRevision)，当前 v\(hand.revision)；核对后另存。")
                    .font(.caption).foregroundStyle(HandStyle.red)
            }
        }
    }

    // One square owns the matrix height. Cells receive concrete dimensions rather than
    // asking 169 nested GeometryReaders to negotiate an unbounded scroll proposal.
    private var matrix: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    let side = max(0, (geometry.size.width - 24) / 13)
                    VStack(spacing: 2) {
                        ForEach(0..<13, id: \.self) { row in
                            HStack(spacing: 2) {
                                ForEach(0..<13, id: \.self) { column in
                                    matrixCell(RangePlan.categories[row * 13 + column], side: side)
                                }
                            }
                        }
                    }
                }
            }
    }

    private func matrixCell(_ category: String, side: CGFloat) -> some View {
        let indices = RangePlan.categoryIndices[category] ?? []
        let available = indices.filter { !RangePlan.combinations[$0].blocked(by: blockers) }
        let weights = available.compactMap { draft?.weights[$0] }
        let mean = weights.isEmpty ? 0 : weights.reduce(0,+) / Double(available.count)
        let delta = categoryDelta(available)
        return Button { selected = category } label: {
            ZStack(alignment: .bottom) {
                Color(red: 0.94, green: 0.93, blue: 0.90)
                Color(red: 0.72, green: 0.74, blue: 0.65).frame(height: side * CGFloat(mean) / 100)
                if available.isEmpty { UserRangeHatch() }
                else if available.count < indices.count {
                    UserRangeHatch().frame(width: 8, height: 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                Text(category).font(.system(size: 9, weight: .semibold)).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if weights.count < available.count {
                    Text("?").font(.system(size: 7)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(1)
                }
                if let delta, abs(delta) > 0.001 {
                    Text(delta > 0 ? "+" : "−").font(.system(size: 16, weight: .black))
                        .foregroundStyle(delta > 0 ? HandStyle.red : HandStyle.green)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).offset(y: -3)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(selected == category ? HandStyle.ink : HandStyle.line, lineWidth: selected == category ? 1.8 : 0.4))
            .opacity(onlyChanges && (delta == nil || abs(delta ?? 0) < 0.001) ? 0.35 : 1)
        }.buttonStyle(.plain)
            .accessibilityLabel("\(category)，\(available.count) 个合法组合，\(weights.count < available.count ? "含未知权重" : String(format: "平均 %.1f%%", mean))")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "已设加权 %.2f", total)).font(.subheadline.weight(.semibold))
                Spacer()
                Text("未知 \(unknown) · 阻断 \(1326 - legal.count)").font(.caption).foregroundStyle(HandStyle.muted)
            }
            if unknown > 0 { Text("待计算 · 尚有未知权重；? 未知、0% 排除、斜纹阻断。") }
            else if total == 0 { Text("无法计算 · 所有合法组合均为 0。") }
            else if dirty { Text(researchEditing ? "临时研究方案 · 在独立研究区明确选择后计算。" : "临时假设已用于全局分析 · 保存以保留命名方案。") }
            else { Text("用户假设 · 各组合权重独立，计算时归一化。") }
        }.font(.caption).foregroundStyle(HandStyle.muted)
    }

    private func combinationDetails(_ category: String) -> some View {
        let indices = RangePlan.categoryIndices[category] ?? []
        let available = indices.filter { !RangePlan.combinations[$0].blocked(by: blockers) }
        let known = available.compactMap { draft?.weights[$0] }
        let sum = known.reduce(0,+) / 100
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(category).font(.headline)
                Spacer()
                Menu("批量赋权") {
                    ForEach([0,25,50,75,100], id: \.self) { weight in
                        Button("本类别 \(weight)%") { assign(indices, Double(weight)) }
                    }
                    Button("本类别未知") { assign(indices, nil) }
                }
            }
            Text(known.count == available.count && !available.isEmpty
                 ? String(format: "平均 %.1f%% · 加权 %.2f · %d 个合法组合", sum * 100 / Double(available.count), sum, available.count)
                 : "\(available.count - known.count) 个未知 · \(indices.count - available.count) 个阻断")
                .font(.caption).foregroundStyle(HandStyle.muted)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(indices, id: \.self) { index in
                    UserRangeCapsule(combo: RangePlan.combinations[index], weight: draft?.weights[index],
                                     blocked: RangePlan.combinations[index].blocked(by: blockers),
                                     reference: comparison?.weights[index]) { assign([index], $0) }
                }
            }
            Text("横拖胶囊调整，松手生效 · 轻点与纵向滚动不改权重")
                .font(.caption2).foregroundStyle(HandStyle.muted)
        }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private var planSelector: some View {
        HStack {
                Menu(draft?.name ?? "我的假设 · 未建立") {
                    ForEach(plans) { plan in Button(plan.name) { selectPlan(plan) } }
                    Divider()
                    Button("新建 · 全部未知") { newPlan(nil) }
                    Button("新建 · 空范围 0%") { newPlan(0) }
                    Button("新建 · 全范围 100%") { newPlan(100) }
                }.font(.subheadline.weight(.semibold))
                Spacer()
                Button { undoEdit() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(edits.isEmpty && draft?.undoableQuickChange == nil).accessibilityLabel("撤销范围修改")
            }
    }

    private var planControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let currentDraft = draft {
                ForEach(RangePlanDependencies.issues(for: currentDraft, hand: hand, plans: dependencyPlans, savedPlans: store.rangePlans, temporaryPlanIDs: Set(transientPlans.values.map(\.id))), id: \.self) { issue in
                    Text("方案失效：" + issue).font(.caption).foregroundStyle(HandStyle.red)
                }
                TextField("方案名称", text: Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0 }))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button { save(asCopy: false) } label: { Text("保存方案").foregroundStyle(.white) }.buttonStyle(.borderedProminent).tint(HandStyle.ink)
                    Button("另存方案") { save(asCopy: true) }.buttonStyle(.bordered)
                    Spacer()
                    if dirty { Text("未保存").font(.caption).foregroundStyle(HandStyle.gold) }
                }
            }
            if !comparisons.isEmpty {
                Picker("比较端点 A", selection: $state.comparisonID) {
                    Text("不比较").tag(nil as UUID?)
                    ForEach(comparisons) { plan in
                        Text("\(plan.after ? "行动后" : "行动前") · \(plan.name)").tag(Optional(plan.id))
                    }
                }
                if let comparison {
                    Text("A：\(comparison.name) v\(comparison.revision)（\(comparison.after ? "行动后" : "行动前")） → B：\(draft?.name ?? "未建立")（\(after ? "行动后" : "行动前")）")
                        .font(.caption).foregroundStyle(HandStyle.muted)
                    ForEach(RangePlanDependencies.issues(for: comparison, hand: hand, plans: dependencyPlans, savedPlans: store.rangePlans, temporaryPlanIDs: Set(transientPlans.values.map(\.id))), id: \.self) { issue in
                        Text("比较端点 A 失效：" + issue + "；仅保留历史权重差异，不代表当前可用先验").font(.caption).foregroundStyle(HandStyle.red)
                    }
                    if comparison.factRevision != hand.revision { Text("比较端点 A 基于旧事实，需重新核对").font(.caption).foregroundStyle(HandStyle.red) }
                    Toggle("仅突出增减 · 权重百分点", isOn: $state.onlyChanges).font(.caption)
                }
            }
        }.handPanel()
    }

    private var learningPanel: some View {
        DisclosureGroup("我的判断、疑问与修改记录") {
            VStack(alignment: .leading, spacing: 10) {
                if draft == nil {
                    Button("先记录我的假设") { newPlan(nil) }
                } else {
                    TextField("我的判断：预计哪些组合继续？", text: Binding(get: { draft?.judgment ?? "" }, set: { draft?.judgment = $0 }), axis: .vertical)
                    TextField("待复盘的疑问", text: Binding(get: { draft?.question ?? "" }, set: { draft?.question = $0 }), axis: .vertical)
                    Button("保存判断与疑问") { draft?.judgmentRecordedAt = Date(); save(asCopy: false) }
                    if let date = draft?.judgmentRecordedAt { Text("判断已记录：" + date.formatted(date: .abbreviated, time: .shortened)) }
                }
                Text("来源面板按当前节点核对审核覆盖；教学简化与用户假设不作策略判错。可主动选择另一方案比较权重。")
                TextField("下一次修改的原因（可选）", text: $state.changeReason, axis: .vertical)
                if let history = draft?.changeHistory, !history.isEmpty {
                    ForEach(history.reversed()) { change in
                        DisclosureGroup("\(change.reason) · \(change.changes.count) 个组合") {
                            ForEach(change.changes.filter { RangePlan.combinations.indices.contains($0.index) }, id: \.index) { item in
                                Text(RangePlan.combinations[item.index].cards.map(\.label).joined() + "  " + weightLabel(item.before) + " → " + weightLabel(item.after))
                                    .monospacedDigit()
                            }
                            Text("事实 v\(change.factRevision) · " + change.date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
            }.font(.caption).foregroundStyle(HandStyle.muted).padding(.top, 10)
        }.font(.subheadline).handPanel()
    }
    private func weightLabel(_ weight: Double?) -> String { weight.map { String(format: "%.0f%%", $0) } ?? "未知" }

    private var sourcePanel: some View {
        RangeCatalogSourcePanel(query: RangeCatalogQuery(hand: hand, eventID: eventID, after: after,
            targetPlayerID: target, format: hand.gameFormat?.rawValue), subjectID: subjectID,
            reveal: reveal, scope: scope, draft: draft, priors: catalogPriors, dependencyPlans: dependencyPlans, savedPlans: store.rangePlans, temporaryPlanIDs: Set(transientPlans.values.map(\.id)), adopt: adoptCatalogPlan)
            .id(context + "|catalog|\(hand.revision)")
    }
    private var catalogPriors: [RangePlan] {
        return dependencyPlans.filter {
            $0.matches(handID: hand.id, eventID: eventID, subjectID: subjectID, targetPlayerID: target,
                       after: false, reveal: reveal, scope: scope)
            && RangePlanDependencies.issues(for: $0, hand: hand, plans: dependencyPlans, savedPlans: store.rangePlans, temporaryPlanIDs: Set(transientPlans.values.map(\.id))).isEmpty
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private func adoptCatalogPlan(_ plan: RangePlan) {
        guard catalogPlanIsCurrent(plan) else { return }
        if dirty {
            pendingCatalogPlan = plan; pendingCatalogDraft = draft; showCatalogReplacement = true
            return
        }
        applyCatalogPlan(plan)
    }
    private func clearCatalogReplacement() {
        showCatalogReplacement = false; pendingCatalogPlan = nil; pendingCatalogDraft = nil
    }
    private func confirmCatalogReplacement(_ plan: RangePlan) {
        let expectedDraft = pendingCatalogDraft
        clearCatalogReplacement()
        guard draft == expectedDraft else { error = "当前稿已变化，请重新检查后采用。"; return }
        // The user's discard decision does not permit an outdated model result.
        guard catalogPlanIsCurrent(plan) else { return }
        applyCatalogPlan(plan)
    }
    private func catalogPlanIsCurrent(_ plan: RangePlan) -> Bool {
        guard plan.matches(handID: hand.id, eventID: eventID, subjectID: subjectID, targetPlayerID: target,
                           after: after, reveal: reveal, scope: scope), plan.factRevision == hand.revision else {
            error = "参考局面已改变，请重新选择来源。"; return false
        }
        let issues = RangePlanDependencies.issues(for: plan, hand: hand, plans: dependencyPlans,
            savedPlans: store.rangePlans, temporaryPlanIDs: Set(transientPlans.values.map(\.id)))
        guard issues.isEmpty else { error = issues.joined(separator: "；"); return false }
        return true
    }
    private func applyCatalogPlan(_ plan: RangePlan) {
        draft = plan; edits = []; selected = nil; comparisonID = nil; onlyChanges = false; error = nil
    }

    private func name(_ id: UUID) -> String { hand.players.first { $0.id == id }?.name ?? "玩家" }
    private func loadContextIfNeeded() {
        // Pin the first resolved range player; later fact edits must not silently pick another.
        if targetID == nil { targetID = target }
        guard state.loadedContext != context else { return }
        clearCatalogReplacement()
        draft = transientPlans[context] ?? plans.first(where: { $0.isActive })
        edits = []; selected = nil; comparisonID = nil; onlyChanges = false; error = nil
        state.loadedContext = context
    }
    private func selectPlan(_ value: RangePlan) {
        var plan = value; plan.isActive = true
        do { try store.upsertRangePlan(plan); draft = plan; edits = []; comparisonID = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func newPlan(_ weight: Double?, keepSelection: Bool = false) {
        if !keepSelection { selected = nil }
        draft = RangePlan(handID: hand.id, eventID: eventID, subjectID: subjectID, targetPlayerID: target, after: after, reveal: reveal, factRevision: hand.revision,
                          name: "\(researchEditing ? "研究" : "假设") \(plans.count + 1)", weights: Array(repeating: weight, count: 1326), scope: scope)
        edits = []; comparisonID = nil
    }
    private func assign(_ indices: [Int], _ weight: Double?, reason: String? = nil) {
        if draft == nil { newPlan(nil, keepSelection: true) }
        guard let previous = draft?.weights else { return }
        let valid = indices.filter { !RangePlan.combinations[$0].blocked(by: blockers) }
        guard valid.contains(where: { previous[$0] != weight }) else { return }
        edits.append(previous)
        for index in valid { draft?.weights[index] = weight }
        recordChange(from: previous, reason: reason ?? (changeReason.isEmpty ? "手动组合赋权" : changeReason))
    }
    private func undoEdit() {
        if let current = draft, current.undoableQuickChange != nil {
            do { draft = try current.undoQuickChange(); error = nil }
            catch { self.error = error.localizedDescription }
            return
        }
        guard let previous = edits.popLast(), let current = draft?.weights else { return }
        let candidate = draft?.latestUndoableChange
        let target = candidate.flatMap { entry -> UUID? in
            var inverse = current
            for item in entry.changes { inverse[item.index] = item.before }
            return inverse == previous ? entry.id : nil
        }
        draft?.weights = previous
        recordChange(from: current, reason: "撤销上次范围修改", undoOf: target)
    }
    private func recordChange(from previous: [Double?], reason: String, undoOf: UUID? = nil) {
        guard let current = draft?.weights else { return }
        let changes = current.indices.compactMap { index -> RangePlanChange.WeightChange? in
            previous[index] == current[index] ? nil : .init(index: index, before: previous[index], after: current[index])
        }
        guard !changes.isEmpty else { return }
        if draft?.changeHistory == nil { draft?.changeHistory = [] }
        draft?.changeHistory?.append(.init(factRevision: hand.revision, reason: reason, changes: changes, undoOfChangeID: undoOf))
    }
    private func save(asCopy: Bool) {
        guard var plan = draft else { return }
        guard !plan.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请填写方案名称"; return }
        // A stale plan is retained for history; reconfirmation creates a new current-fact plan.
        if asCopy || plan.factRevision != hand.revision { plan.id = UUID(); plan.name += " · 副本"; plan.revision = 0 }
        plan.isActive = true; plan.factRevision = hand.revision; plan.revision += 1; plan.updatedAt = Date()
        do { try store.upsertRangePlan(plan); draft = plan; edits = []; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func categoryDelta(_ indices: [Int]) -> Double? {
        guard let draft, let comparison, !indices.isEmpty,
              indices.allSatisfy({ draft.weights[$0] != nil && comparison.weights[$0] != nil }) else { return nil }
        return indices.reduce(0) { $0 + (draft.weights[$1]! - comparison.weights[$1]!) } / Double(indices.count)
    }
}

private struct UserRangeHatch: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for x in stride(from: -size.height, through: size.width, by: 5) {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x + size.height, y: size.height))
            }
            context.stroke(path, with: .color(HandStyle.muted.opacity(0.4)), lineWidth: 0.8)
        }
    }
}

private struct UserRangeCapsule: View {
    let combo: RangePlanCombo
    let weight: Double?
    let blocked: Bool
    let reference: Double?
    let commit: (Double) -> Void
    @State private var live: Double?
    private var shown: Double? { live ?? weight }
    var body: some View {
        visual
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(combo.cards.reversed().map(\.label).joined() + (blocked ? " 已阻断" : " 权重"))
            .accessibilityValue(blocked ? "不可编辑" : shown.map { String(format: "%.0f%%", $0) } ?? "未知")
            .accessibilityAdjustableAction { direction in
                guard !blocked else { return }
                if direction == .increment { commit(min(100, (weight ?? 0) + 5)) }
                if direction == .decrement { commit(max(0, (weight ?? 0) - 5)) }
            }
            .accessibilityAction(named: Text("增加 5%")) { if !blocked { commit(min(100, (weight ?? 0) + 5)) } }
            .accessibilityAction(named: Text("减少 5%")) { if !blocked { commit(max(0, (weight ?? 0) - 5)) } }
            .accessibilityAction(named: Text("设为 50%")) { if !blocked { commit(50) } }
    }
    private var visual: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Color(red: 0.94, green: 0.93, blue: 0.90)
                if blocked { UserRangeHatch() }
                else { Color(red: 0.72, green: 0.74, blue: 0.65).frame(width: geometry.size.width * CGFloat(shown ?? 0) / 100) }
                HStack(spacing: 3) {
                    ForEach(Array(combo.cards.reversed())) { PlayingCard(value: $0.label, small: true) }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(blocked ? "阻断" : shown.map { String(format: "%.0f%%", $0) } ?? "未知")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        if !blocked, let reference, let shown, reference != shown {
                            Text(String(format: "%+.0f pp", shown - reference)).font(.system(size: 9))
                        }
                    }
                }.padding(.horizontal, 7)
            }.clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(HandStyle.line, lineWidth: 0.8))
                .overlay {
                    if !blocked {
                        UserRangePan(changed: { x in live = adjusted(x, width: geometry.size.width) }, ended: { x, completed in
                            let value = adjusted(x, width: geometry.size.width); live = nil
                            if completed && abs(x) > 11 { commit(value) }
                        })
                    }
                }
        }.frame(height: 58)
    }
    private func adjusted(_ x: CGFloat, width: CGFloat) -> Double {
        let relative = Double(x / max(CGFloat(80), width - 24))
        return min(100, max(0, (weight ?? 0) + (relative * 100).rounded()))
    }
}

private struct UserRangePan: UIViewRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(changed: changed, ended: ended) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear; view.isAccessibilityElement = false
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator; pan.maximumNumberOfTouches = 1; view.addGestureRecognizer(pan)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.changed = changed; context.coordinator.ended = ended }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var changed: (CGFloat) -> Void
        var ended: (CGFloat, Bool) -> Void
        init(changed: @escaping (CGFloat) -> Void, ended: @escaping (CGFloat, Bool) -> Void) { self.changed = changed; self.ended = ended }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.3
        }
        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            let x = recognizer.translation(in: recognizer.view).x
            switch recognizer.state {
            case .changed: changed(x)
            case .ended: ended(x, true)
            case .cancelled, .failed: ended(x, false)
            default: break
            }
        }
    }
}
