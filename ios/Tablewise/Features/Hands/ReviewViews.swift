import SwiftUI

struct ReviewQueueView: View {
    @ObservedObject var store: LocalStore
    var handIDs: Set<UUID>? = nil
    var onOpenHand: (UUID) -> Void
    @State private var filter = "pending"
    @State private var editing: NodeAnnotation?
    @State private var error: String?
    private var annotations: [NodeAnnotation] {
        store.nodeAnnotations.filter { handIDs == nil || handIDs!.contains($0.handID) }
    }
    private var filtered: [NodeAnnotation] {
        annotations.filter {
            switch filter {
            case "pending": return $0.reviewStatus == "pending"
            case "completed": return $0.reviewStatus == "completed"
            case "bookmarks": return $0.isBookmarked
            default: return true
            }
        }
    }
    private var missing: [ReviewMissingItem] {
        store.hands.filter { handIDs == nil || handIDs!.contains($0.id) }.flatMap(ReviewMissingItem.collect)
    }
    var body: some View {
        List {
            Section {
                Picker("记录类型", selection: $filter) {
                    Text("待复盘").tag("pending")
                    Text("已完成").tag("completed")
                    Text("书签").tag("bookmarks")
                    Text("全部").tag("all")
                }.pickerStyle(.segmented)
            }
            Section("节点记录 · \(filtered.count)") {
                if filtered.isEmpty { Text("此分类暂无节点记录").foregroundStyle(HandStyle.muted) }
                ForEach(filtered) { annotation in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(store.hands.first { $0.id == annotation.handID }?.title ?? "原牌局缺失").font(.headline)
                        Text(nodeTitle(annotation)).font(.subheadline).foregroundStyle(HandStyle.muted)
                        if annotation.isMissingEvent {
                            Label("原节点已删除 · 笔记仍保留", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(HandStyle.gold)
                            Text(annotation.eventID.uuidString).font(.caption2.monospaced()).textSelection(.enabled)
                        }
                        if let question = annotation.question, !question.isEmpty { Text(question).font(.subheadline) }
                        else if !annotation.text.isEmpty { Text(annotation.text).font(.subheadline).lineLimit(3) }
                        HStack {
                            Button(annotation.reviewStatus == "completed" ? "查看心得" : "问题、判断与心得") { editing = annotation }.buttonStyle(.borderless)
                            Spacer()
                            Button("定位原节点") { open(handID: annotation.handID, eventID: annotation.eventID) }
                                .buttonStyle(.borderless).disabled(annotation.isMissingEvent)
                        }.font(.caption.weight(.medium))
                    }.padding(.vertical, 5)
                }
            }
            Section {
                if missing.isEmpty { Text("当前没有发现待补事实").foregroundStyle(HandStyle.muted) }
                ForEach(missing) { item in
                    Button { open(handID: item.handID, eventID: item.eventID) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            Text(item.message).font(.caption).foregroundStyle(HandStyle.muted)
                        }
                    }.foregroundStyle(HandStyle.ink)
                }
            } header: { Text("待补信息 · \(missing.count)") } footer: {
                Text("待补信息由当前事实推导，修正后更新；复盘完成状态由你手动记录，不代表牌局缺项已自动补齐。")
            }
        }
        .scrollContentBackground(.hidden).background(HandStyle.canvas)
        .navigationTitle("回顾与待办").navigationBarTitleDisplayMode(.inline).tint(HandStyle.green)
        .sheet(item: $editing) { note in ReviewNodeEditor(handID: note.handID, eventID: note.eventID, store: store) }
        .alert("无法定位", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func nodeTitle(_ note: NodeAnnotation) -> String {
        guard let hand = store.hands.first(where: { $0.id == note.handID }) else { return "原牌局缺失" }
        let event = hand.events.first { $0.id == note.eventID } ?? note.removedEvent
        guard let event else { return "原节点缺失" }
        let player = hand.players.first { $0.id == event.playerID }?.name ?? "公共事件"
        let number = hand.events.firstIndex { $0.id == event.id }.map { "#\($0 + 1) · " } ?? ""
        return number + event.street.label + " · " + player + " · " + event.kind.label
    }
    private func open(handID: UUID, eventID: UUID?) {
        guard let hand = store.hands.first(where: { $0.id == handID }) else { error = "原牌局已不存在。"; return }
        if let eventID, !hand.events.contains(where: { $0.id == eventID }) { error = "原节点已删除；笔记保留，不会跳转到邻近节点或恢复已删除事实。"; return }
        do {
            let sessionID = store.sessions.first { $0.hands.contains { $0.handID == handID } }?.id
            try store.updateSelection(StoreSelection(lastHandID: handID, selectedEventID: eventID, lastSessionID: sessionID))
            onOpenHand(handID)
        } catch { self.error = error.localizedDescription }
    }
}

struct ReviewCaptureContext {
    let subjectID: UUID
    let after: Bool
    let reveal: Bool
    var scope: RangePlan.Scope = .decision
    var transientPlans: [String: RangePlan] = [:]
}

struct ReviewNodeEditor: View {
    let handID: UUID
    let eventID: UUID
    @ObservedObject var store: LocalStore
    var captureContext: ReviewCaptureContext? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var question = ""
    @State private var judgment = ""
    @State private var reflection = ""
    @State private var bookmarked = false
    @State private var status = "note"
    @State private var snapshots: [RangePlan] = []
    @State private var capture: ReviewRangeCapture?
    @State private var loaded = false
    @State private var error: String?
    private var original: NodeAnnotation? { store.nodeAnnotations.first { $0.handID == handID && $0.eventID == eventID } }
    private var hand: HandRecord? { store.hands.first { $0.id == handID } }
    private var eventExists: Bool { hand?.events.contains { $0.id == eventID } == true }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(hand?.title ?? "原牌局缺失").font(.headline)
                    if !eventExists {
                        Label("原节点已删除；仅编辑保留的笔记", systemImage: "exclamationmark.triangle").foregroundStyle(HandStyle.gold)
                    }
                    Text("节点 \(eventID.uuidString)").font(.caption2.monospaced()).textSelection(.enabled)
                    Toggle("节点书签", isOn: $bookmarked)
                    Picker("复盘状态", selection: $status) {
                        if original?.reviewStatus == nil { Text("仅笔记").tag("note") }
                        Text("待复盘").tag("pending")
                        Text("已完成").tag("completed")
                    }
                }
                Section("问题") { TextField("这个决定有什么值得核对？", text: $question, axis: .vertical).lineLimit(3...8) }
                Section("自己的判断") { TextField("先记下判断及依赖的条件", text: $judgment, axis: .vertical).lineLimit(3...8) }
                Section("复盘心得") { TextField("完成后记录发现、条件变化与下一步", text: $reflection, axis: .vertical).lineLimit(3...8) }
                Section("节点笔记") { TextField("其他观察与原有笔记", text: $text, axis: .vertical).lineLimit(3...8) }
                Section {
                    if let capture {
                        Text("\(hand?.players.first { $0.id == capture.subjectID }?.name ?? "原分析对象") · \(capture.after ? "行动后" : "行动前") · \(capture.reveal ? "揭牌" : "决策") · \(capture.scope == .decision ? "决策范围" : "完整范围研究")")
                            .font(.caption).foregroundStyle(HandStyle.muted)
                        if let ancestors = capture.dependencyPlanSnapshots, !ancestors.isEmpty {
                            DisclosureGroup("当时的前序假设 · \(ancestors.count) 个冻结版本") {
                                ForEach(ancestors) { ancestor in
                                    NavigationLink { ReviewRangeSnapshotView(plan: ancestor, hand: hand) } label: {
                                        Text("\(ancestor.name) · v\(ancestor.revision) · 事实 v\(ancestor.factRevision)")
                                    }
                                }
                            }
                        }
                        Text(capture.capturedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(HandStyle.muted)
                        ForEach(Array(capture.issues.enumerated()), id: \.offset) { _, issue in
                            Label(issue, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(HandStyle.gold)
                        }
                    }
                    if snapshots.isEmpty { Text("未保存可用的范围权重快照；不代表空范围或 0%。").foregroundStyle(HandStyle.muted) }
                    ForEach(snapshots) { plan in
                        NavigationLink { ReviewRangeSnapshotView(plan: plan, hand: hand) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(plan.name)
                                if capture?.temporaryPlanIDs.contains(plan.id) == true {
                                    Text("临时假设快照 · 不依赖方案库保存").font(.caption).foregroundStyle(HandStyle.gold)
                                }
                                Text("范围 v\(plan.revision) · 事实 v\(plan.factRevision) · \(plan.after ? "After" : "Before")")
                                    .font(.caption).foregroundStyle(HandStyle.muted)
                            }
                        }
                    }
                    Button(snapshots.isEmpty ? "记录当前范围假设" : "更新为当前范围假设") { captureCurrent() }
                        .disabled(!eventExists || captureContext == nil)
                    if captureContext == nil {
                        Text("从节点分析页打开，才能记录明确对象、时点及视角的当前假设；此处保留已存快照。").font(.caption).foregroundStyle(HandStyle.muted)
                    }
                } header: { Text("当时的假设版本") } footer: {
                    Text("只冻结当前上下文实际启用的假设，临时编辑优先。缺项、过期或无效输入会明确记录，不会改用旧方案。以后修改范围不会覆盖此快照。")
                }
                if let error { Section { Text(error).foregroundStyle(HandStyle.red) } }
            }
            .scrollContentBackground(.hidden).background(HandStyle.canvas).scrollDismissesKeyboard(.interactively)
            .navigationTitle("节点复盘").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .task {
                guard !loaded else { return }; loaded = true
                if let original {
                    text = original.text; question = original.question ?? ""; judgment = original.judgment ?? ""
                    reflection = original.reflection ?? ""; bookmarked = original.isBookmarked
                    status = original.reviewStatus ?? "note"; snapshots = original.rangePlanSnapshots ?? []; capture = original.rangeCapture
                } else { captureCurrent() }
            }
        }.tint(HandStyle.green)
    }
    private func captureCurrent() {
        guard let context = captureContext, let hand, eventExists else { return }
        func matches(_ plan: RangePlan) -> Bool {
            plan.handID == handID && plan.eventID == eventID && plan.subjectID == context.subjectID
                && plan.after == context.after && plan.reveal == context.reveal && plan.resolvedScope == context.scope
        }
        let saved = store.rangePlans.filter { matches($0) && $0.isActive }
        // Keep the same precedence as analysis: any explicit draft shadows saved choices,
        // even when that draft is stale, incomplete, empty or invalid.
        let temporary = context.transientPlans.values.filter { matches($0) }
        let targets = Set(saved.map(\.targetPlayerID) + temporary.map(\.targetPlayerID))
        var record = ReviewRangeCapture(subjectID: context.subjectID, after: context.after, reveal: context.reveal, scope: context.scope)
        var captured: [RangePlan] = []
        let dependencyPlans = RangePlanDependencies.environment(saved: store.rangePlans, temporary: Array(context.transientPlans.values))
        if !hand.players.contains(where: { $0.id == context.subjectID }) {
            record.issues.append("分析对象已不属于此手牌；当前假设不可用于计算。")
        }
        for target in targets.sorted(by: { $0.uuidString < $1.uuidString }) {
            let drafts = temporary.filter { $0.targetPlayerID == target }
            let chosen = drafts.isEmpty ? saved.filter { $0.targetPlayerID == target } : drafts
            let name = hand.players.first { $0.id == target }?.name ?? "原范围玩家"
            if chosen.count > 1 { record.issues.append("\(name)：有多个启用假设，计算需先明确选择；此处保留候选状态。") }
            for plan in chosen.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let isTemporary = !drafts.isEmpty && !store.rangePlans.contains(plan)
                guard plan.isValidWeights, (0...1_000_000_000).contains(plan.revision),
                      (0...1_000_000_000).contains(plan.factRevision), hand.players.contains(where: { $0.id == target }),
                      hand.players.contains(where: { $0.id == context.subjectID }),
                      !captured.contains(where: { $0.id == plan.id }) else {
                    record.issues.append("\(name) · \(plan.name)：权重或方案身份无效，未冻结非法权重，也未改用旧方案。")
                    continue
                }
                captured.append(plan)
                for issue in RangePlanDependencies.issues(for: plan, hand: hand, plans: dependencyPlans, savedPlans: store.rangePlans, temporaryPlanIDs: Set(context.transientPlans.values.map(\.id))) {
                    record.issues.append("\(name) · \(plan.name)：" + issue)
                }
                if isTemporary { record.temporaryPlanIDs.append(plan.id) }
                if plan.factRevision != hand.revision || plan.removedEvent != nil {
                    record.issues.append("\(name) · \(plan.name)：事实版本已变化或节点失效；保留原假设待核对。")
                }
                if plan.weights.contains(where: { $0 == nil }) {
                    record.issues.append("\(name) · \(plan.name)：包含未知权重；未知不视为 0%。")
                } else if plan.weights.allSatisfy({ $0 == 0 }) {
                    record.issues.append("\(name) · \(plan.name)：明确空范围，当前不能计算。")
                }
            }
        }
        if context.scope == .decision, let node = HandReducer.project(hand).nodes.first(where: { $0.id == eventID }) {
            let state = context.after ? node.after : node.before
            for player in state.players where !player.folded {
                let fact = hand.players.first { $0.id == player.id }
                let known = (context.reveal || player.id == context.subjectID) && fact?.holeCards.count == 2
                if !known && !targets.contains(player.id) {
                    record.issues.append("\(fact?.name ?? "玩家")：当前未启用范围假设；未改用旧方案。")
                }
            }
            if state.blocked { record.issues.append("当前事实存在阻断冲突；假设快照不代表可计算结果。") }
        }
        if targets.isEmpty && record.issues.isEmpty { record.issues.append("此上下文尚无启用的范围假设。") }
        record.dependencyPlanSnapshots = RangePlanDependencies.ancestors(of: captured, plans: dependencyPlans)
        let ancestorEventIDs = Set((record.dependencyPlanSnapshots ?? []).map(\.eventID))
        record.dependencyEvents = hand.events.filter { ancestorEventIDs.contains($0.id) }
        snapshots = captured
        capture = record
    }
    private func save() {
        if status == "completed" && reflection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = "请记录复盘心得后标为已完成。"; return
        }
        var note = original ?? NodeAnnotation(handID: handID, eventID: eventID)
        note.text = text; note.question = question; note.judgment = judgment; note.reflection = reflection
        note.isBookmarked = bookmarked; note.reviewStatus = status == "note" ? nil : status
        note.rangePlanSnapshots = snapshots
        note.rangeCapture = capture
        note.rangePlanIDs = snapshots.filter { snapshot in
            capture?.temporaryPlanIDs.contains(snapshot.id) != true
                && store.rangePlans.contains { $0.id == snapshot.id && $0.handID == handID && $0.eventID == eventID }
        }.map(\.id)
        note.completedAt = status == "completed" ? (original?.completedAt ?? Date()) : nil
        do { try store.upsertAnnotation(note); dismiss() } catch { self.error = error.localizedDescription }
    }
}

private struct ReviewRangeSnapshotView: View {
    let plan: RangePlan
    var hand: HandRecord?
    @State private var query = ""
    private var categories: [String] { RangePlan.categories.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        List {
            Section {
                LabeledContent("范围版本", value: "v\(plan.revision)")
                LabeledContent("事实版本", value: "v\(plan.factRevision)")
                LabeledContent("范围玩家", value: hand?.players.first { $0.id == plan.targetPlayerID }?.name ?? plan.targetPlayerID.uuidString)
                LabeledContent("分析对象", value: hand?.players.first { $0.id == plan.subjectID }?.name ?? plan.subjectID.uuidString)
                LabeledContent("时点 / 视角", value: "\(plan.after ? "After" : "Before") · \(plan.reveal ? "揭牌" : "决策")")
                Text(RangeCatalogRepository.bundled.sourceSummary(plan: plan, hand: nil)).font(.footnote).foregroundStyle(HandStyle.muted)
                if let dependency = plan.parentDependency {
                    Text("生成时先验：\(dependency.origin == .saved ? "已保存" : "临时") · \(dependency.parentID.uuidString) · v\(dependency.parentRevision) · 事实 v\(dependency.parentFactRevision)").font(.caption)
                    Text("先验内容指纹：" + dependency.parentWeightsHash).font(.caption).textSelection(.enabled)
                } else if plan.catalogReference?.actionId != nil {
                    Text("旧行动派生方案没有用户先验身份记录；当时的依赖无法确认。").font(.caption).foregroundStyle(HandStyle.gold)
                }
                Text("这是当时保存的权重快照；不展示当前计算结果，也不自动替换当前方案。").font(.footnote).foregroundStyle(HandStyle.muted)
            }
            Section("组合权重 · 未知与 0 分开") {
                ForEach(categories, id: \.self) { category in
                    let indices = RangePlan.categoryIndices[category] ?? []
                    DisclosureGroup(category) {
                        ForEach(indices, id: \.self) { index in
                            HStack {
                                Text(RangePlan.combinations[index].cards.map(\.label).joined(separator: " "))
                                Spacer()
                                Text(plan.weights.indices.contains(index) ? (plan.weights[index].map { String(format: "%.1f%%", $0) } ?? "未知") : "无效缺项")
                            }.font(.subheadline).monospacedDigit()
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "查找 AKs、QQ 等牌型")
        .scrollContentBackground(.hidden).background(HandStyle.canvas)
        .navigationTitle(plan.name).navigationBarTitleDisplayMode(.inline)
    }
}
