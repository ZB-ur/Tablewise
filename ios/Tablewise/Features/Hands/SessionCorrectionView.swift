import SwiftUI

/// A detached preview: the store checks its baseline again before committing the whole chain.
struct SessionCorrectionView: View {
    let preview: SessionCorrectionPreview
    @ObservedObject var store: LocalStore
    var boardChangePreview: HandBoardChangePreview? = nil
    var onClose: (() -> Void)? = nil
    var onCommitTrace: ((String) -> Void)? = nil
    let onCommitted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var committed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Button("取消更正") { close() }
                        .frame(minWidth: 72, minHeight: 44)
                    Spacer()
                    Text("历史更正预览").font(.headline)
                    Spacer()
                    Button("确认更正") { commit() }
                        .fontWeight(.semibold)
                        .frame(minWidth: 72, minHeight: 44)
                        .disabled(!preview.canCommit || committed)
                }.buttonStyle(.plain).padding(.horizontal, 16)
                Divider()
                Form {
                    Section("更正范围") {
                        Text(preview.session.title)
                        Text(preview.session.corrections?.last?.reason ?? "历史记录更正")
                        Text("逐手核对起始筹码与结算余额。确认后整条受影响记录一起保存；本页预览不会改动原记录。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let boardChangeImpact {
                        Section("本手公共牌\(boardChangeImpact.operationTitle)") {
                            HandBoardChangeImpactContent(preview: boardChangeImpact)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowBackground(Color.clear)
                        }
                    }
                    SessionCorrectionEventChangesSection(impacts: preview.eventImpacts, session: preview.session)
                    ForEach(preview.impacts) { impact in
                        Section("第 \(impact.number) 手") {
                            configurationImpact(impact)
                            ForEach(impact.players) { player in
                                playerImpact(player, handID: impact.handID)
                            }
                            Label(impact.settlementReplayed ? "结算已重新核对，可随更正保存" : "本手没有可沿用的确认结算，余额按已知情况保留", systemImage: impact.settlementReplayed ? "checkmark.circle" : "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(impact.settlementReplayed ? .green : .secondary)
                            ForEach(Array(impact.issues.enumerated()), id: \.offset) { _, issue in
                                Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                    }
                    if !preview.conflicts.isEmpty {
                        Section("需先解决的冲突") {
                            ForEach(Array(preview.conflicts.enumerated()), id: \.offset) { _, conflict in
                                Label(conflict, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            }
                            Text("当前预览不能提交；原始手牌、结算及人员资金记录均保持原状。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section("原记录归档") {
                        Text("原事件、受影响手牌及起始配置会保留在更正历史中。旧结算保留来源；失效的分析和待核对金额不会自动变成已确认结果。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if preview.impacts.isEmpty && preview.canCommit {
                            Text("本次更正没有改变已发牌的筹码快照，仍会保存事件更正及原记录归档。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert("更正未保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private var boardChangeImpact: HandBoardChangePreview? {
        guard let boardChangePreview, boardChangePreview.event.kind == .deal,
              case .hand(let requested) = preview.request,
              requested.id == boardChangePreview.original.id,
              requested.events == boardChangePreview.proposed.events else { return nil }
        // Keep the captured original; show the reducer's final candidate when one is available.
        guard let candidate = preview.hands.first(where: { $0.id == requested.id }) else { return boardChangePreview }
        return HandBoardChangePreview(original: boardChangePreview.original, event: boardChangePreview.event, proposed: candidate)
    }

    private func playerImpact(_ impact: SessionCorrectionPlayerImpact, handID: UUID) -> some View {
        let hand = preview.hands.first { $0.id == handID } ?? store.hands.first { $0.id == handID }
        let unit = hand?.configuration.chipUnit ?? preview.session.initialConfiguration.chipUnit
        let name = hand?.players.first { $0.id == impact.playerID }?.name
            ?? store.hands.first { $0.id == handID }?.players.first { $0.id == impact.playerID }?.name
            ?? preview.session.players.first { $0.id == impact.playerID }?.name ?? "未知玩家"
        return VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.subheadline.weight(.semibold))
            LabeledContent("参与", value: "\(impact.previouslyDealt ? "已发牌" : "未发牌") → \(impact.proposedDealt ? "已发牌" : "未发牌")")
            LabeledContent("座位", value: "\(impact.previouslyDealt ? String(impact.previousSeat + 1) : "—") → \(impact.proposedDealt ? String(impact.proposedSeat + 1) : "—")")
            LabeledContent("起始筹码", value: "\(unit.format(impact.previousStart)) → \(unit.format(impact.proposedStart))")
            LabeledContent("结算余额", value: "\(unit.format(impact.previousEnd)) → \(unit.format(impact.proposedEnd))")
        }.font(.subheadline).padding(.vertical, 4)
    }

    private func configurationImpact(_ impact: SessionCorrectionImpact) -> some View {
        let old = impact.previousConfiguration
        let new = impact.proposedConfiguration
        return VStack(alignment: .leading, spacing: 6) {
            Text("位置与本手规则").font(.subheadline.weight(.semibold))
            LabeledContent("牌局类型", value: "\(impact.previousGameFormat?.title ?? "未注明") → \(impact.proposedGameFormat?.title ?? "未注明")")
            LabeledContent("按钮 · BTN", value: "座位 \(old.buttonSeat + 1) → 座位 \(new.buttonSeat + 1)")
            LabeledContent("小盲 · SB", value: "\(old.chipUnit.format(units: old.smallBlind)) → \(new.chipUnit.format(units: new.smallBlind))")
            LabeledContent("大盲 · BB", value: "\(old.chipUnit.format(units: old.bigBlind)) → \(new.chipUnit.format(units: new.bigBlind))")
            LabeledContent("前注", value: "\(anteLabel(old)) → \(anteLabel(new))")
            if old.tableCapacity != new.tableCapacity { LabeledContent("桌容量", value: "\(old.tableCapacity) → \(new.tableCapacity)") }
            if old.chipUnit != new.chipUnit { LabeledContent("最小筹码单位", value: "\(old.chipUnit.decimal) → \(new.chipUnit.decimal)") }
        }.font(.subheadline).padding(.vertical, 4)
    }
    private func anteLabel(_ configuration: HandConfiguration) -> String {
        switch configuration.ante {
        case .none: return "无"
        case .perPlayer(let n): return "每人 " + configuration.chipUnit.format(units: n)
        case .bigBlind(let n): return "大盲 " + configuration.chipUnit.format(units: n)
        case .button(let n): return "按钮 " + configuration.chipUnit.format(units: n)
        }
    }

    private func commit() {
        guard preview.canCommit, !committed else { return }
        #if DEBUG
        onCommitTrace?("start")
        #endif
        do {
            if let boardChangePreview {
                guard let hand = store.hands.first(where: { $0.id == boardChangePreview.original.id }),
                      try boardChangePreview.isCurrent(for: hand) else {
                    throw LocalStoreError.invalid("原记录已变化，请取消后重新预览公共牌\(boardChangePreview.operationTitle)影响。")
                }
            }
            try store.commitSessionCorrection(preview)
            committed = true
            #if DEBUG
            onCommitTrace?("success")
            #endif
            onCommitted()
            close()
        } catch {
            #if DEBUG
            onCommitTrace?("failure")
            #endif
            self.error = error.localizedDescription
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}

/// Shared by the repair route and final preview so selected companion moves remain visible throughout.
struct SessionCorrectionEventChangesSection: View {
    let impacts: [SessionCorrectionEventImpact]
    let session: SessionRecord

    var body: some View {
        if !impacts.isEmpty {
            Section("本次事件更正") {
                ForEach(impacts) { impact in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.label(impact.proposed.kind, session: session)).font(.subheadline.weight(.semibold))
                        LabeledContent("生效时间", value: "第 \(impact.previous.effectiveHandNumber) 手前 → 第 \(impact.proposed.effectiveHandNumber) 手前")
                        Text("原事实：" + Self.label(impact.previous.kind, session: session)).font(.footnote).foregroundStyle(.secondary)
                        Text(impact.id.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
        }
    }

    static func label(_ kind: SessionEventKind, session: SessionRecord) -> String {
        func name(_ id: UUID) -> String {
            if let person = session.players.first(where: { $0.id == id }) { return person.name }
            for event in session.events {
                switch event.kind {
                case .join(let person, _), .replaceIdentity(_, let person):
                    if person.id == id { return person.name }
                default: break
                }
            }
            return "未知玩家"
        }
        let unit = session.initialConfiguration.chipUnit
        switch kind {
        case .join(let person, let seat): return "\(person.name) 加入座位 \(seat + 1)"
        case .replaceIdentity(let old, let person): return "\(name(old)) 替换为新身份 \(person.name)"
        case .buyIn(let id, let amount): return "\(name(id)) 买入 \(unit.format(amount))"
        case .topUp(let id, let amount): return "\(name(id)) 补码 \(unit.format(amount))"
        case .cashOut(let id, let amount): return "\(name(id)) 带走 \(unit.format(amount))"
        case .calibrate(let id, let amount): return "\(name(id)) 实测校准 \(unit.format(amount))"
        case .leave(let id): return "\(name(id)) 离桌"
        case .sitOut(let id): return "\(name(id)) 暂离"
        case .returnToTable(let id, let play): return "\(name(id)) 返回 · \(play ? "参与" : "等待")"
        case .moveSeat(let id, let seat): return "\(name(id)) 移至座位 \(seat + 1)"
        case .swapSeats(let first, let second): return "\(name(first)) 与 \(name(second)) 换座"
        case .rules(let small, let big, let ante):
            var parts: [String] = []
            if let small { parts.append("SB " + unit.format(units: small)) }
            if let big { parts.append("BB " + unit.format(units: big)) }
            if let ante {
                switch ante {
                case .none: parts.append("无前注")
                case .perPlayer(let amount): parts.append("每人前注 " + unit.format(units: amount))
                case .bigBlind(let amount): parts.append("大盲前注 " + unit.format(units: amount))
                case .button(let amount): parts.append("按钮前注 " + unit.format(units: amount))
                }
            }
            return "规则变更 · " + parts.joined(separator: " / ")
        }
    }
}
