import SwiftUI

struct HandSettlementView: View {
    let hand: HandRecord
    var store: LocalStore? = nil
    let onSave: (HandRecord) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selections: [Int: SettlementSelection] = [:]
    @State private var error: String?
    @State private var confirmed = false
    @State private var correcting = false
    @State private var correctionPreview: SessionCorrectionPreview?
    @State private var showCorrectionPreview = false
    @State private var savedResult: HandSettlementRecord?

    private var preview: SettlementPreview { HandSettlement.preview(hand, selections: selections) }
    private var existingCurrent: Bool { hand.settlement?.isCurrent(for: hand) == true }
    private var unit: ChipUnit { hand.configuration.chipUnit }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if confirmed || (existingCurrent && !correcting) {
                        Label("结算已确认，不会重复入账", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if correcting {
                        Label("更正已确认结算", systemImage: "pencil.circle")
                        Text("逐池核对实际赢家、零头与获奖金额。保存后原结果保留为更正历史，不重复累加筹码。").font(.footnote).foregroundStyle(.secondary)
                    } else if hand.settlement != nil {
                        Label("原结算已失效，按当前事实重新核对", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        Text("原结算记录保留；确认新结果后进入更正历史。").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("先退回未匹配投入，再逐池分配。金额按最小筹码单位结算。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    LabeledContent("最小筹码单位", value: unit.decimal)
                }
                if confirmed, let savedResult {
                    savedContent(savedResult)
                } else if existingCurrent && !correcting, let saved = hand.settlement {
                    savedContent(saved)
                } else {
                    previewContent(preview)
                }
                if let history = hand.settlementHistory, !history.isEmpty {
                    Section("更正历史") {
                        ForEach(history.reversed()) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.confirmedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                                LabeledContent("结算依据", value: sourceDescription(record.source))
                                    .font(.footnote).foregroundStyle(.secondary)
                                ForEach(record.pots) { pot in
                                    Text("\(pot.id == 0 ? "主池" : "边池 \(pot.id)")：\(pot.payments.map { "\(name($0.playerID)) \((pot.amountInputUnit ?? unit).format(units: $0.units))" }.joined(separator: " · "))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("\(pot.id == 0 ? "主池" : "边池 \(pot.id)")依据：\(sourceDescription(pot.source))")
                                        .font(.footnote).foregroundStyle(.secondary)
                                    Text("金额依据：\(pot.amountInputs == nil ? "自动平分与零头" : "手动核对金额")")
                                        .font(.footnote).foregroundStyle(.secondary)
                                    if let inputUnit = pot.amountInputUnit {
                                        Text("核对时最小筹码单位：\(inputUnit.decimal)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    Text("未知余额保持待核对。结算不自动补码，也不扣取任何费用。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("结算核对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(correcting && !confirmed ? "取消更正" : "完成") {
                        if correcting && !confirmed {
                            correcting = false
                            selections = [:]
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if existingCurrent && !correcting && !confirmed {
                        Button("更正结算") { beginCorrection() }
                    } else {
                        Button(confirmed ? "已确认" : (correcting ? "确认更正" : "确认结算")) { save() }
                            .disabled((existingCurrent && !correcting) || confirmed || !preview.canConfirm)
                    }
                }
            }
            .sheet(isPresented: $showCorrectionPreview) {
                if let correctionPreview, let store {
                    SessionCorrectionView(preview: correctionPreview, store: store) {
                        savedResult = store.hands.first { $0.id == hand.id }?.settlement
                        confirmed = true
                        correcting = false
                        showCorrectionPreview = false
                    }
                }
            }
            .alert("无法确认结算", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    @ViewBuilder private func previewContent(_ current: SettlementPreview) -> some View {
        if !current.refunds.isEmpty {
            Section("退回未匹配投入") {
                ForEach(current.refunds) { payment in LabeledContent(name(payment.playerID), value: unit.format(units: payment.units)) }
            }
        }
        ForEach(current.pots) { pot in
            Section(pot.id == 0 ? "主池 · \(unit.format(units: pot.units))" : "边池 \(pot.id) · \(unit.format(units: pot.units))") {
                Text(pot.source == .manual ? "根据实际结果选择本池赢家，可选择多人平分。" : "依据\(pot.source == .fold ? "唯一未弃牌玩家" : "已知牌张与争池资格")自动判定。")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(pot.eligibleIDs, id: \.self) { id in
                    if pot.source == .manual {
                        Button { toggleWinner(id, in: pot) } label: {
                            HStack {
                                Text(name(id)).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: pot.winnerIDs.contains(id) ? "checkmark.circle.fill" : "circle")
                            }
                        }.disabled(confirmed)
                    } else {
                        HStack {
                            Text(name(id))
                            Spacer()
                            if pot.winnerIDs.contains(id) { Label("赢家", systemImage: "checkmark").foregroundStyle(.green) }
                        }
                    }
                }
                if pot.winnerIDs.count > 1 && pot.units % Int64(pot.winnerIDs.count) > 0 {
                    Picker("零头首先分给", selection: Binding<UUID?>(get: { selections[pot.id]?.oddChipFirst ?? pot.oddChipFirst }, set: { id in
                        // A changed split starts with automatic amounts; stale drafts cannot carry across schemes.
                        selections[pot.id] = .init(winnerIDs: pot.winnerIDs, oddChipFirst: id)
                    })) {
                        ForEach(pot.winnerIDs, id: \.self) { id in Text(name(id)).tag(Optional(id)) }
                    }.disabled(confirmed)
                    Text("默认从按钮后顺时针的本池赢家开始逐个分配。改变零头归属后，金额核对输入重置为自动分配。").font(.caption).foregroundStyle(.secondary)
                }
                if !pot.winnerIDs.isEmpty {
                    Toggle("手动核对获奖金额", isOn: Binding(get: { selections[pot.id]?.amountInputs != nil }, set: { enabled in
                        var selection = selections[pot.id] ?? .init(winnerIDs: pot.winnerIDs, oddChipFirst: pot.oddChipFirst)
                        selection.amountInputs = enabled ? pot.payments.map { .init(playerID: $0.playerID, amount: unit.format(units: $0.units)) } : nil
                        selections[pot.id] = selection
                    })).disabled(confirmed)
                    if selections[pot.id]?.amountInputs != nil {
                        ForEach(pot.payments) { payment in
                            LabeledContent("\(name(payment.playerID)) 获奖") {
                                TextField("获奖金额", text: amountBinding(payment.playerID, in: pot))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(minWidth: 80, maxWidth: 140)
                                    .accessibilityLabel("\(pot.id == 0 ? "主池" : "边池 \(pot.id)") \(name(payment.playerID)) 获奖金额")
                            }
                            Text("合法分配：\(unit.format(units: payment.units))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("金额须符合本池平分与零头方案。调整赢家或零头后，请重新核对金额。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(pot.payments) { payment in
                            LabeledContent("\(name(payment.playerID)) 获奖", value: unit.format(units: payment.units))
                        }
                    }
                    if let check = current.amountChecks.first(where: { $0.id == pot.id }) {
                        LabeledContent("本池已分配", value: check.allocatedUnits.map { unit.format(units: $0) } ?? "待填写合法金额")
                        LabeledContent("本池差额", value: differenceDescription(check.difference))
                            .foregroundStyle(check.difference == 0 ? Color.secondary : Color.orange)
                    }
                }
            }
        }
        if !current.pots.isEmpty {
            Section("分配总额核对") {
                LabeledContent("可分配总额", value: unit.format(units: current.distributedUnits))
                LabeledContent("已分配总额", value: current.allocatedUnits.map { unit.format(units: $0) } ?? "待填写合法金额")
                LabeledContent("差额", value: differenceDescription(current.allocatedUnits.map { current.distributedUnits - $0 }))
                    .foregroundStyle(current.allocatedUnits == current.distributedUnits ? Color.secondary : Color.orange)
                Text("退回未匹配投入单列，不计入获奖分配总额。差额为零且各池分配合法后才能确认。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if !current.issues.isEmpty {
            Section("待核对") { ForEach(current.issues, id: \.self) { Text($0).foregroundStyle(.orange) } }
        }
        if !current.finalBalances.isEmpty {
            Section("结算后筹码") {
                ForEach(current.finalBalances) { balance in
                    LabeledContent(name(balance.playerID), value: balance.amount.units == nil ? "待核对" : unit.format(balance.amount))
                }
            }
        }
    }
    @ViewBuilder private func savedContent(_ saved: HandSettlementRecord) -> some View {
        Section("已确认结算依据") {
            LabeledContent("结算依据", value: sourceDescription(saved.source))
        }
        if !saved.refunds.isEmpty {
            Section("已退回未匹配投入") {
                ForEach(saved.refunds) { payment in LabeledContent(name(payment.playerID), value: unit.format(units: payment.units)) }
            }
        }
        ForEach(saved.pots) { pot in
            Section(pot.id == 0 ? "主池" : "边池 \(pot.id)") {
                LabeledContent("底池", value: unit.format(units: pot.units))
                LabeledContent("本池依据", value: sourceDescription(pot.source))
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("金额依据", value: pot.amountInputs == nil ? "自动平分与零头" : "手动核对金额")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(pot.payments) { payment in LabeledContent(name(payment.playerID), value: unit.format(units: payment.units)) }
            }
        }
        Section("已确认筹码") {
            ForEach(saved.finalBalances) { balance in LabeledContent(name(balance.playerID), value: balance.amount.units == nil ? "待核对" : unit.format(balance.amount)) }
            LabeledContent("确认时间", value: saved.confirmedAt.formatted(date: .abbreviated, time: .shortened))
        }
    }
    private func sourceDescription(_ source: SettlementSource) -> String {
        switch source {
        case .manual: "手工指定"
        case .fold: "唯一未弃牌结束"
        case .automaticShowdown: "已知牌摊牌自动判定"
        case .mixed: "混合来源（各池分别说明）"
        }
    }
    private func name(_ id: UUID) -> String { hand.players.first { $0.id == id }?.name ?? "未知玩家" }
    private func differenceDescription(_ difference: Int64?) -> String {
        guard let difference else { return "待核对" }
        return difference == 0 ? "0" : "\(difference > 0 ? "少" : "多") \(unit.format(units: abs(difference)))"
    }
    private func amountBinding(_ id: UUID, in pot: SettledPot) -> Binding<String> {
        Binding(get: { selections[pot.id]?.amountInputs?.first { $0.playerID == id }?.amount ?? "" }, set: { text in
            guard var selection = selections[pot.id], var inputs = selection.amountInputs,
                  let index = inputs.firstIndex(where: { $0.playerID == id }) else { return }
            inputs[index].amount = text
            selection.amountInputs = inputs
            selections[pot.id] = selection
        })
    }
    private func toggleWinner(_ id: UUID, in pot: SettledPot) {
        var winners = selections[pot.id]?.winnerIDs ?? pot.winnerIDs
        if winners.contains(id) { winners.removeAll { $0 == id } } else { winners.append(id) }
        let oldOdd = selections[pot.id]?.oddChipFirst
        selections[pot.id] = .init(winnerIDs: winners, oddChipFirst: oldOdd.flatMap { winners.contains($0) ? $0 : nil })
    }
    private func beginCorrection() {
        guard let saved = hand.settlement else { return }
        selections = Dictionary(uniqueKeysWithValues: saved.pots.map { ($0.id, SettlementSelection(winnerIDs: $0.winnerIDs, oddChipFirst: $0.oddChipFirst, amountInputs: $0.amountInputs)) })
        correcting = true
    }
    private func save() {
        guard !confirmed else { return }
        do {
            guard preview.canConfirm else { throw SettlementError.invalid(preview.issues.joined(separator: "\n")) }
            if let store, let session = store.sessions.first(where: { session in
                session.hands.contains { $0.handID == hand.id && $0.number < session.hands.count }
            }) {
                correctionPreview = store.previewSessionCorrection(session,
                    request: .settlement(handID: hand.id, selections: selections))
                showCorrectionPreview = true
                return
            }
            let updated = try HandSettlement.confirm(hand, selections: selections, correction: correcting)
            try onSave(updated)
            savedResult = updated.settlement
            confirmed = true
        } catch { self.error = error.localizedDescription }
    }
}
