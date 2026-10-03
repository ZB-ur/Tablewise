import SwiftUI

struct RememberedPotScreen: View {
    let hand: HandRecord
    let nodeEventID: UUID?
    let after: Bool
    let onSave: (HandRecord) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var certainty: ValueCertainty = .exact
    @State private var source = "用户记忆"
    @State private var loaded = false
    @State private var error: String?

    private var existing: RememberedPot? { hand.rememberedPot(nodeEventID: nodeEventID, after: after) }
    private var node: HandNode? { HandReducer.project(hand).nodes.first { $0.id == nodeEventID } }
    private var snapshot: HandSnapshot? {
        if nodeEventID == nil { return HandReducer.project(hand).initial }
        guard let node else { return nil }
        return after ? node.after : node.before
    }
    private var remembered: ChipAmount? {
        if certainty == .unknown { return .init(units: nil, source: source) }
        guard var amount = hand.configuration.chipUnit.parse(amountText, certainty: certainty) else { return nil }
        amount.source = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "用户记忆" : source
        return amount
    }
    private var difference: Int64? {
        guard let remembered = remembered?.units, let snapshot, !snapshot.blocked, let derived = snapshot.pot.units else { return nil }
        return remembered - derived
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("记录时点") {
                    if let node {
                        LabeledContent(node.event.street.title, value: "\(node.event.kind.title) · \(after ? "行动后" : "行动前")")
                    } else if nodeEventID == nil {
                        Text("起始状态 · 强制投入前")
                    } else {
                        Text("原节点已不存在；保留记忆记录待核对。").foregroundStyle(.orange)
                    }
                }
                Section("用户记忆底池") {
                    Picker("精度", selection: $certainty) {
                        Text("精确").tag(ValueCertainty.exact)
                        Text("近似").tag(ValueCertainty.approximate)
                        Text("未知").tag(ValueCertainty.unknown)
                    }.pickerStyle(.segmented)
                    if certainty != .unknown {
                        TextField("底池金额 · 筹码", text: $amountText).keyboardType(.decimalPad)
                        Text("最小筹码单位 \(hand.configuration.chipUnit.decimal)").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("记忆来源", text: $source)
                    if let existing {
                        LabeledContent("上次记录", value: existing.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section {
                    LabeledContent("记忆底池", value: remembered.map { hand.configuration.chipUnit.format($0) } ?? "待输入有效金额")
                    LabeledContent("事件推导底池", value: derivedText)
                    if let difference {
                        if difference == 0 {
                            Label("记忆与当前事件推导一致", systemImage: "checkmark.circle")
                        } else {
                            Text("记忆值比推导值\(difference > 0 ? "多" : "少") \(hand.configuration.chipUnit.format(units: difference > 0 ? difference : -difference))")
                                .foregroundStyle(.orange)
                            Text("请核对行动或记忆值。差异解决前，依赖单一确定底池的精确分析需要暂停。").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("缺少可核对的确定值，暂不计算差额。").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("分别核对")
                } footer: {
                    Text("记忆底池独立保存，不覆盖事件推导金额，不改动下注或结算账目。")
                }
                Section {
                    Button("保存记忆底池") { save() }.frame(maxWidth: .infinity).disabled(remembered == nil)
                    if existing != nil {
                        Button("移除这条记忆记录", role: .destructive) {
                            var updated = hand
                            updated.rememberedPots?.removeAll { $0.nodeEventID == nodeEventID && $0.after == after }
                            updated.updatedAt = Date()
                            do { try onSave(updated); dismiss() } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .navigationTitle("记忆底池")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let existing {
                    certainty = existing.amount.certainty
                    if let units = existing.amount.units { amountText = hand.configuration.chipUnit.format(units: units) }
                    source = existing.amount.source
                }
            }
            .alert("尚未保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private var derivedText: String {
        guard let snapshot else { return "节点缺失" }
        guard !snapshot.blocked else { return "前序冲突 · 待核对" }
        return hand.configuration.chipUnit.format(snapshot.pot)
    }
    private func save() {
        guard let remembered else { error = "请输入非负金额，且金额必须是最小筹码单位的整数倍。"; return }
        var updated = hand
        var item = existing ?? RememberedPot(nodeEventID: nodeEventID, after: after, amount: remembered)
        item.amount = remembered
        item.recordedAt = Date()
        var memories = updated.rememberedPots ?? []
        memories.removeAll { $0.nodeEventID == nodeEventID && $0.after == after }
        memories.append(item)
        updated.rememberedPots = memories
        updated.updatedAt = item.recordedAt
        do { try onSave(updated); dismiss() } catch { self.error = error.localizedDescription }
    }
}
