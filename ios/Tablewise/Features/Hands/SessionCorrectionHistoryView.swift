import SwiftUI

/// Reads frozen pre-correction records only. It never enters current calculations or editing routes.
struct SessionCorrectionHistoryView: View {
    let sessionID: UUID
    @ObservedObject var store: LocalStore
    private var session: SessionRecord? { store.sessions.first { $0.id == sessionID } }

    var body: some View {
        Group {
            if let session {
                let archives = session.corrections ?? []
                List {
                    Section {
                        Text("每次更正保留更正前的事件、受影响手牌与起始配置，供只读核对。")
                        Text("当前记录在场次页面查看。存档不计入当前统计，也不代表该次更正后的冻结版本。")
                            .font(.footnote).foregroundStyle(HandStyle.muted)
                    }
                    if archives.isEmpty {
                        Section { Text("本场次暂无已保存的更正历史").foregroundStyle(HandStyle.muted) }
                    } else {
                        Section("已保存的更正") {
                            ForEach(archives.reversed()) { archive in
                                NavigationLink {
                                    SessionCorrectionArchiveView(archive: archive, references: session.hands)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(archive.reason).font(.headline)
                                        Text(archive.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.subheadline).foregroundStyle(HandStyle.muted)
                                        Text("更正前存档 · \(archive.previousHands.count) 手 · \(archive.previousEvents.count) 条场次事件")
                                            .font(.caption).foregroundStyle(HandStyle.muted)
                                    }.padding(.vertical, 3)
                                }
                                .accessibilityLabel("查看更正前存档，\(archive.reason)，\(archive.createdAt.formatted(date: .abbreviated, time: .shortened))，记录 \(archive.id.uuidString.prefix(8))")
                                .accessibilityIdentifier("session-correction-archive-\(archive.id.uuidString)")
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden).background(HandStyle.canvas)
            } else { ContentUnavailableView("场次不存在", systemImage: "rectangle.stack") }
        }
        .navigationTitle("场次更正历史").navigationBarTitleDisplayMode(.inline)
        .tint(HandStyle.green)
    }
}

private struct SessionCorrectionArchiveView: View {
    let archive: SessionCorrectionArchive
    let references: [SessionHandReference]
    private var identities: ArchiveIdentities { ArchiveIdentities(archive) }

    var body: some View {
        List {
            Section("更正前存档 · 只读") {
                Text(archive.reason).font(.headline)
                LabeledContent("更正保存时间", value: archive.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("以下是本次更正前保存的事实。该档案未保存更正后的冻结版本；返回场次查看当前记录，当前记录可能已有后续修改。")
                    .font(.footnote).foregroundStyle(HandStyle.muted)
            }
            ArchiveRulesSection(configuration: archive.previousInitialConfiguration, title: "原场次起始规则")
            Section("原场次起始座位与筹码") {
                ForEach(archive.previousInitialSeats.sorted { $0.seat < $1.seat }) { seat in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(identities.name(seat.playerID)) · 座位 \(seat.seat + 1)")
                        LabeledContent("起始筹码", value: archive.previousInitialConfiguration.chipUnit.format(seat.balance))
                        Text("\(participation(seat.participation)) · 身份 \(seat.playerID.uuidString.prefix(8))")
                            .font(.caption).foregroundStyle(HandStyle.muted)
                    }.padding(.vertical, 3)
                }
            }
            Section("更正前场次事件") {
                if archive.previousEvents.isEmpty { Text("存档没有场次事件").foregroundStyle(HandStyle.muted) }
                ForEach(Array(archive.previousEvents.enumerated()), id: \.element.id) { index, event in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(index + 1). \(eventLabel(event.kind))").font(.subheadline.weight(.semibold))
                        Text("第 \(event.effectiveHandNumber) 手前\(event.cancelledAt == nil ? "生效" : " · 已撤销")")
                            .font(.subheadline)
                        if !event.note.isEmpty { Text(event.note).font(.footnote).foregroundStyle(HandStyle.muted) }
                        Text("事件 \(event.id.uuidString.prefix(8))").font(.caption).foregroundStyle(HandStyle.muted)
                    }.padding(.vertical, 3)
                }
            }
            Section("受影响手牌 · 更正前存档") {
                if archive.previousHands.isEmpty {
                    Text("此次更正未改变已保存手牌，档案仅保留场次来源。").foregroundStyle(HandStyle.muted)
                }
                ForEach(archive.previousHands) { hand in
                    let title = handTitle(hand)
                    NavigationLink {
                        ArchivedCorrectionHandView(hand: hand, title: title)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(title).font(.headline)
                            Text("\(hand.players.count) 位玩家 · \(hand.events.count) 条原事件 · \(hand.settlement == nil ? "无原确认结算" : "含原结算记录")")
                                .font(.caption).foregroundStyle(HandStyle.muted)
                        }.padding(.vertical, 3)
                    }
                    .accessibilityLabel("查看\(title)更正前存档，手牌 \(hand.id.uuidString.prefix(8))")
                    .accessibilityIdentifier("archived-hand-\(archive.id.uuidString)-\(hand.id.uuidString)")
                }
            }
        }
        .scrollContentBackground(.hidden).background(HandStyle.canvas)
        .navigationTitle("更正前存档").navigationBarTitleDisplayMode(.inline)
    }

    private func handTitle(_ hand: HandRecord) -> String {
        if let reference = references.first(where: { $0.handID == hand.id }) { return "第 \(reference.number) 手" }
        return hand.title
    }
    private func participation(_ value: SessionParticipation) -> String {
        switch value { case .playing: "参与"; case .sittingOut: "暂离"; case .waiting: "等待"; case .left: "离桌" }
    }
    private func eventLabel(_ kind: SessionEventKind) -> String {
        let unit = archive.previousInitialConfiguration.chipUnit
        switch kind {
        case .join(let person, let seat): return "\(person.name) 加入座位 \(seat + 1)"
        case .replaceIdentity(let old, let person): return "\(identities.name(old)) 被新身份 \(person.name) 替换"
        case .leave(let id): return "\(identities.name(id)) 离桌"
        case .sitOut(let id): return "\(identities.name(id)) 暂离"
        case .returnToTable(let id, let play): return "\(identities.name(id)) 返回 · \(play ? "参与" : "等待")"
        case .moveSeat(let id, let seat): return "\(identities.name(id)) 移至座位 \(seat + 1)"
        case .swapSeats(let first, let second): return "\(identities.name(first)) 与 \(identities.name(second)) 换座"
        case .buyIn(let id, let amount): return "\(identities.name(id)) 买入 \(unit.format(amount))"
        case .topUp(let id, let amount): return "\(identities.name(id)) 补码 \(unit.format(amount))"
        case .cashOut(let id, let amount): return "\(identities.name(id)) 带走筹码 \(unit.format(amount))"
        case .calibrate(let id, let amount): return "\(identities.name(id)) 实测校准 \(unit.format(amount))"
        case .rules(let small, let big, let ante):
            var fields: [String] = []
            if let small { fields.append("SB " + unit.format(units: small)) }
            if let big { fields.append("BB " + unit.format(units: big)) }
            if let ante { fields.append(archiveAnte(ante, unit: unit)) }
            return "规则变更 · " + fields.joined(separator: " / ")
        }
    }
}

private struct ArchivedCorrectionHandView: View {
    let hand: HandRecord
    let title: String
    private var unit: ChipUnit { hand.configuration.chipUnit }

    var body: some View {
        List {
            Section("更正前手牌 · 只读") {
                Text(hand.title).font(.headline)
                Text("名单、底牌、原行动及结算均来自本次更正前存档，不参与当前余额或统计。")
                    .font(.footnote).foregroundStyle(HandStyle.muted)
                LabeledContent("存档事实版本", value: "\(hand.revision)")
                if let format = hand.gameFormat { LabeledContent("牌局类型", value: format.title) }
                if !hand.notes.isEmpty { Text(hand.notes).font(.footnote) }
            }
            ArchiveRulesSection(configuration: hand.configuration, title: "本手原规则")
            Section("原参与名单与底牌") {
                ForEach(hand.players.sorted { $0.seat < $1.seat }) { player in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(player.name)\(player.isHero ? " · You" : "") · 座位 \(player.seat + 1)")
                            .font(.subheadline.weight(.semibold))
                        LabeledContent("原起始筹码", value: unit.format(player.startingStack))
                        LabeledContent("原底牌", value: player.holeCards.isEmpty ? "未知" : player.holeCards.map(\.label).joined(separator: " "))
                        Text("身份 \(player.id.uuidString.prefix(8))").font(.caption).foregroundStyle(HandStyle.muted)
                    }.padding(.vertical, 3)
                }
            }
            Section("原行动与发牌事件") {
                if hand.events.isEmpty { Text("原手牌没有行动事件").foregroundStyle(HandStyle.muted) }
                ForEach(Array(hand.events.enumerated()), id: \.element.id) { index, event in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(index + 1). \(event.street.title) · \(eventLabel(event))")
                            .font(.subheadline.weight(.semibold))
                        Text("来源：\(event.source)").font(.caption).foregroundStyle(HandStyle.muted)
                    }.padding(.vertical, 3)
                }
            }
            if let settlement = hand.settlement {
                archivedSettlement(settlement, title: "原结算记录")
            } else {
                Section("原结算记录") { Text("更正前尚无确认结算，余额保持待核对。").foregroundStyle(HandStyle.muted) }
            }
            if let history = hand.settlementHistory, !history.isEmpty {
                ForEach(history.reversed()) { settlement in
                    archivedSettlement(settlement, title: "更正前已有的结算历史")
                }
            }
        }
        .scrollContentBackground(.hidden).background(HandStyle.canvas)
        .navigationTitle("\(title) · 原存档").navigationBarTitleDisplayMode(.inline)
    }

    private func name(_ id: UUID) -> String {
        hand.players.first(where: { $0.id == id })?.name ?? "未包含姓名的身份 \(id.uuidString.prefix(8))"
    }
    private func eventLabel(_ event: HandEvent) -> String {
        if event.kind == .deal { return "公共牌 " + event.cards.map(\.label).joined(separator: " ") }
        let actor = event.playerID.map(name) ?? "未指定身份"
        let amount = event.amount.map { " " + unit.format($0) } ?? ""
        return actor + " · " + event.kind.title + amount
    }
    private func archivedSettlement(_ record: HandSettlementRecord, title: String) -> some View {
        Section(title) {
            LabeledContent("原确认时间", value: record.confirmedAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("依据事实版本", value: "\(record.factRevision)")
            LabeledContent("原记录状态", value: record.isCurrent(for: hand) ? "在此存档版本有效" : "在此存档版本已失效或待核对")
            LabeledContent("结算来源", value: settlementSource(record.source))
            ForEach(record.refunds) { refund in
                LabeledContent("\(name(refund.playerID)) · 退回未匹配投入", value: unit.format(units: refund.units))
            }
            ForEach(record.pots) { pot in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(pot.id == 0 ? "主池" : "边池 \(pot.id)") · \(unit.format(units: pot.units))")
                        .font(.subheadline.weight(.semibold))
                    Text("资格：" + pot.eligibleIDs.map(name).joined(separator: "、")).font(.footnote)
                    Text("赢家：" + pot.winnerIDs.map(name).joined(separator: "、")).font(.footnote)
                    ForEach(pot.payments) { payment in
                        LabeledContent("\(name(payment.playerID)) · 原获奖分配", value: unit.format(units: payment.units))
                    }
                    if let id = pot.oddChipFirst { Text("零头首先分配给 " + name(id)).font(.footnote) }
                }.padding(.vertical, 3)
            }
            ForEach(record.finalBalances) { balance in
                LabeledContent("\(name(balance.playerID)) · 原结算余额", value: unit.format(balance.amount))
            }
        }
    }
    private func settlementSource(_ source: SettlementSource) -> String {
        switch source { case .fold: "唯一未弃牌玩家"; case .automaticShowdown: "已知牌张摊牌"; case .manual: "手动确认"; case .mixed: "混合来源" }
    }
}

private struct ArchiveRulesSection: View {
    let configuration: HandConfiguration
    let title: String
    var body: some View {
        Section(title) {
            LabeledContent("桌容量", value: "\(configuration.tableCapacity) 人")
            LabeledContent("按钮 · BTN", value: "座位 \(configuration.buttonSeat + 1)")
            LabeledContent("小盲 · SB", value: configuration.chipUnit.format(units: configuration.smallBlind))
            LabeledContent("大盲 · BB", value: configuration.chipUnit.format(units: configuration.bigBlind))
            LabeledContent("前注", value: archiveAnte(configuration.ante, unit: configuration.chipUnit))
            LabeledContent("最小筹码单位", value: configuration.chipUnit.decimal)
        }
    }
}

private func archiveAnte(_ ante: AnteRule, unit: ChipUnit) -> String {
    switch ante {
    case .none: "无前注"
    case .perPlayer(let n): "每人前注 " + unit.format(units: n)
    case .bigBlind(let n): "大盲前注 " + unit.format(units: n)
    case .button(let n): "按钮前注 " + unit.format(units: n)
    }
}

/// Names come from archived UUIDs only; a current same-name player is never used as a substitute.
private struct ArchiveIdentities {
    private let names: [UUID: String]
    init(_ archive: SessionCorrectionArchive) {
        var result: [UUID: String] = [:]
        for event in archive.previousEvents {
            switch event.kind {
            case .join(let player, _), .replaceIdentity(_, let player): result[player.id] = player.name
            default: break
            }
        }
        for hand in archive.previousHands.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            for player in hand.players { result[player.id] = player.name }
        }
        names = result
    }
    func name(_ id: UUID) -> String {
        names[id] ?? "存档未含姓名 · 身份 \(id.uuidString.prefix(8))"
    }
}
