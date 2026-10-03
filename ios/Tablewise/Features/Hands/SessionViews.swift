import SwiftUI

struct SessionDetailView: View {
    let sessionID: UUID
    @ObservedObject var store: LocalStore
    var onOpenHand: (UUID) -> Void
    @State private var allowUnknown = false
    @State private var buttonOverride = -1
    @State private var managing = false
    @State private var selectedPlayer: SessionPlayer?
    @State private var correctingEvent: SessionEvent?
    @State private var error: String?
    @State private var confirmEnd = false
    @State private var title = ""
    @State private var renaming = false
    private var session: SessionRecord? { store.sessions.first { $0.id == sessionID } }

    var body: some View {
        Group {
            if let session {
                let preview = SessionReducer.previewNextHand(session, hands: store.hands,
                    buttonSeatOverride: buttonOverride < 0 ? nil : buttonOverride, allowIncompleteResult: allowUnknown)
                List {
                    Section {
                        LabeledContent("场次状态", value: session.status == .active ? "进行中" : "已结束")
                        LabeledContent("已录入", value: "\(session.hands.count) 手")
                        Button("修改场次名称") { title = session.title; renaming = true }
                        NavigationLink {
                            SessionCorrectionHistoryView(sessionID: session.id, store: store)
                        } label: {
                            LabeledContent("场次更正历史", value: "\(session.corrections?.count ?? 0) 次")
                        }
                        .accessibilityLabel("查看场次更正历史，共 \(session.corrections?.count ?? 0) 次")
                        .accessibilityIdentifier("session-correction-history-entry")
                    }
                    Section("场次回顾") {
                        let ids = Set(session.hands.map(\.handID))
                        let records = store.hands.filter { ids.contains($0.id) }
                        let totals = ReviewTotals(hands: records)
                        let notes = store.nodeAnnotations.filter { ids.contains($0.handID) }
                        LabeledContent("自己已确认 / 待核对结算", value: "\(totals.confirmed) / \(totals.pending)")
                        if totals.withoutHero > 0 {
                            LabeledContent("未参与 / 未标记自己", value: "\(totals.withoutHero) 手")
                        }
                        if totals.ambiguousHero > 0 {
                            LabeledContent("自己标记冲突", value: "\(totals.ambiguousHero) 手")
                        }
                        LabeledContent("自己扑克净额", value: totals.chipLabel)
                        LabeledContent("自己逐手 BB 净额", value: totals.bbLabel)
                        LabeledContent("标记节点 / 待复盘", value: "\(notes.filter(\.isBookmarked).count) / \(notes.filter { $0.reviewStatus == "pending" }.count)")
                        NavigationLink("本场次复盘与待补信息") {
                            ReviewQueueView(store: store, handIDs: ids, onOpenHand: onOpenHand)
                        }
                        Text("仅合计自己的有效确定结算。资金进出单独列账，未知结果不当作已结算盈亏。").font(.footnote).foregroundStyle(HandStyle.muted)
                    }
                    Section("牌局记录") {
                        ForEach(session.hands.reversed()) { reference in
                            if let hand = store.hands.first(where: { $0.id == reference.handID }) {
                                Button { open(hand) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text("第 \(reference.number) 手").font(.headline)
                                            Text(hand.settlement?.isCurrent(for: hand) == true ? "已结算" : "待结算 / 待核对")
                                                .font(.caption).foregroundStyle(HandStyle.muted)
                                        }
                                        Spacer()
                                        Text(hand.configuration.chipUnit.format(HandReducer.project(hand).latest.pot)).monospacedDigit()
                                        Image(systemName: "chevron.right").font(.caption)
                                    }
                                }.foregroundStyle(HandStyle.ink)
                            } else { Text("第 \(reference.number) 手记录缺失").foregroundStyle(HandStyle.red) }
                        }
                    }
                    if session.status == .active {
                        nextHandSection(session, preview: preview)
                    }
                    Section {
                        ForEach(preview.seats) { seat in
                            if let player = preview.identities.first(where: { $0.id == seat.playerID }) {
                                Button { selectedPlayer = player } label: {
                                    HStack {
                                        HandPortrait(seat: seat.seat, hero: player.isHero)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(player.name + (player.isHero ? " · You" : ""))
                                            Text("座位 \(seat.seat + 1) · \(participationLabel(seat.participation))")
                                                .font(.caption).foregroundStyle(HandStyle.muted)
                                        }
                                        Spacer()
                                        Text(preview.configuration.chipUnit.format(seat.balance)).monospacedDigit()
                                    }
                                }.foregroundStyle(HandStyle.ink)
                            }
                        }
                        if session.status == .active { Button("人员、筹码与下一手规则") { managing = true } }
                    } header: { Text("玩家 · 下一手余额") } footer: {
                        Text("未知余额不会自动设为 100。玩家统计仅计入本场次，资金进出与牌局输赢分开。")
                    }
                    if !preview.pendingEvents.isEmpty {
                        Section("第 \(preview.number) 手待生效变更") {
                            ForEach(preview.pendingEvents) { event in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(sessionEventLabel(event.kind, identities: preview.identities, unit: preview.configuration.chipUnit))
                                    if !event.note.isEmpty { Text(event.note).font(.caption).foregroundStyle(HandStyle.muted) }
                                    Button("撤销此变更", role: .destructive) { cancel(event.id) }.font(.caption)
                                }
                            }
                        }
                    }
                    let appliedEvents = session.events.filter { $0.cancelledAt == nil && $0.effectiveHandNumber <= session.hands.count }
                    if !appliedEvents.isEmpty {
                        Section {
                            ForEach(appliedEvents.reversed()) { event in
                                Button { correctingEvent = event } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(sessionEventLabel(event.kind, identities: preview.identities, unit: preview.configuration.chipUnit))
                                        Text("第 \(event.effectiveHandNumber) 手前已生效 · 预览更正")
                                            .font(.caption).foregroundStyle(HandStyle.muted)
                                    }
                                }.foregroundStyle(HandStyle.ink)
                            }
                        } header: { Text("已生效事件 · 历史更正") } footer: {
                            Text("更正先核对后续筹码、规则和结算。人员名单不自动迁移；跨校准的未决衔接会阻止提交。")
                        }
                    }
                    if !preview.finance.isEmpty {
                        Section("独立资金记录") {
                            ForEach(preview.finance.reversed()) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(sessionEventLabel(entry.event.kind, identities: preview.identities, unit: preview.configuration.chipUnit))
                                    Text("第 \(entry.event.effectiveHandNumber) 手前 · \(preview.configuration.chipUnit.format(entry.before)) → \(preview.configuration.chipUnit.format(entry.after))")
                                        .font(.caption).foregroundStyle(HandStyle.muted)
                                    let delta = entry.delta
                                    let formattedDelta = preview.configuration.chipUnit.format(delta)
                                    let signedDelta = (delta.units.map { $0 > 0 } == true && preview.configuration.chipUnit.value != nil ? "+" : "") + formattedDelta
                                    if case .calibrate = entry.event.kind {
                                        LabeledContent("校准差额", value: signedDelta).font(.footnote)
                                    } else {
                                        LabeledContent("资金变化", value: signedDelta).font(.footnote)
                                    }
                                    LabeledContent("记录时间") {
                                        Text(entry.event.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                                    }.font(.footnote).foregroundStyle(HandStyle.muted)
                                }
                            }
                        }
                    }
                    Section {
                        Button(session.status == .active ? "结束场次" : "恢复场次", role: session.status == .active ? .destructive : nil) {
                            if session.status == .active { confirmEnd = true } else { setEnded(false) }
                        }
                    } footer: { Text("结束场次不补填未知结算，记录仍可回看。") }
                }
                .scrollContentBackground(.hidden).background(HandStyle.canvas)
                .navigationTitle(session.title).navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $managing) { SessionManagementView(sessionID: sessionID, store: store) }
                .sheet(item: $correctingEvent) { event in
                    SessionEventCorrectionScreen(sessionID: sessionID, eventID: event.id, store: store)
                }
                .sheet(item: $selectedPlayer) { player in SessionPlayerView(sessionID: sessionID, playerID: player.id, store: store) }
            } else { ContentUnavailableView("场次不存在", systemImage: "rectangle.stack") }
        }
        .tint(HandStyle.green)
        .alert("未能完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
        .alert("结束场次？", isPresented: $confirmEnd) {
            Button("取消", role: .cancel) {}
            Button("结束", role: .destructive) { setEnded(true) }
        } message: { Text("未结算的牌局仍保持待核对；之后可以恢复此场次。") }
        .alert("场次名称", isPresented: $renaming) {
            TextField("名称", text: $title)
            Button("取消", role: .cancel) {}
            Button("保存") {
                guard var session else { return }
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { error = "名称不能为空。"; return }
                session.title = trimmed; session.updatedAt = Date(); save(session)
            }
        }
    }
    private func nextHandSection(_ session: SessionRecord, preview: SessionNextHandPreview) -> some View {
        Section {
            LabeledContent("桌容量", value: "\(preview.configuration.tableCapacity) 个座位")
            LabeledContent("入座 · 下一手生效后", value: preview.issues.isEmpty ? "\(preview.seats.filter { $0.participation != .left }.count) 人" : "待核对")
            LabeledContent("下一手发牌", value: preview.issues.isEmpty ? "\(preview.players.count) 人" : "待核对")
            LabeledContent("小盲 · SB", value: preview.configuration.chipUnit.format(units: preview.configuration.smallBlind))
            LabeledContent("大盲 · BB", value: preview.configuration.chipUnit.format(units: preview.configuration.bigBlind))
            LabeledContent("前注", value: nextHandAnteLabel(preview.configuration))
            LabeledContent("最小筹码单位", value: preview.configuration.chipUnit.decimal)
            Picker("按钮 · BTN", selection: $buttonOverride) {
                Text("自动轮换").tag(-1)
                ForEach(preview.players) { player in Text("座位 \(player.seat + 1) · \(player.name)").tag(player.seat) }
            }
            ForEach(preview.players) { player in
                HStack {
                    Text(player.name)
                    Spacer()
                    Text(preview.positions[player.id] ?? "—").font(.caption.weight(.semibold))
                    Text(preview.configuration.chipUnit.format(player.startingStack)).monospacedDigit()
                }
            }
            if let last = session.hands.last, let hand = store.hands.first(where: { $0.id == last.handID }), hand.settlement?.isCurrent(for: hand) != true {
                Toggle("保留未知结算，继续下一手", isOn: $allowUnknown)
                Text("尚未确认的结算会使后续余额保持未知；这不会把当前底池当作已分配。")
                    .font(.footnote).foregroundStyle(HandStyle.muted)
            }
            if !preview.unconfirmedBalanceIDs.isEmpty {
                Text("\(preview.unconfirmedBalanceIDs.count) 位玩家余额为近似或未知。可在人员与筹码管理中实测校准。")
                    .font(.footnote).foregroundStyle(HandStyle.gold)
            }
            ForEach(Array(preview.issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.footnote).foregroundStyle(HandStyle.red) }
            Button("确认名单并开始第 \(preview.number) 手") { startNext() }
                .disabled(!preview.canStart)
        } header: { Text("下一手预览 · 第 \(preview.number) 手") } footer: {
            Text("以上规则在第 \(preview.number) 手生效，并继承确认余额与待生效变更。按钮可在此明确调整；已保存历史不随新规则改写。")
        }
    }
    private func nextHandAnteLabel(_ configuration: HandConfiguration) -> String {
        switch configuration.ante {
        case .none: "无前注"
        case .perPlayer(let amount): "每人前注 " + configuration.chipUnit.format(units: amount)
        case .bigBlind(let amount): "大盲前注 " + configuration.chipUnit.format(units: amount)
        case .button(let amount): "按钮前注 " + configuration.chipUnit.format(units: amount)
        }
    }
    private func startNext() {
        guard var session else { return }
        do {
            let hand = try SessionReducer.startNextHand(&session, hands: store.hands,
                buttonSeatOverride: buttonOverride < 0 ? nil : buttonOverride, allowIncompleteResult: allowUnknown)
            try store.saveSession(session, hand: hand)
            try store.updateSelection(StoreSelection(lastHandID: hand.id, selectedEventID: hand.events.last?.id, lastSessionID: session.id))
            allowUnknown = false; buttonOverride = -1
            onOpenHand(hand.id)
        } catch { self.error = error.localizedDescription }
    }
    private func open(_ hand: HandRecord) {
        do {
            let selected = store.selection.lastHandID == hand.id ? store.selection.selectedEventID : hand.events.last?.id
            try store.updateSelection(StoreSelection(lastHandID: hand.id, selectedEventID: selected, lastSessionID: sessionID))
            onOpenHand(hand.id)
        } catch { self.error = error.localizedDescription }
    }
    private func cancel(_ id: UUID) {
        guard var session else { return }
        do { try SessionReducer.cancel(eventID: id, in: &session); try store.upsertSession(session) }
        catch { self.error = error.localizedDescription }
    }
    private func setEnded(_ ended: Bool) {
        guard var session else { return }
        SessionReducer.setEnded(ended, session: &session); save(session)
    }
    private func save(_ session: SessionRecord) {
        do { try store.upsertSession(session) } catch { self.error = error.localizedDescription }
    }
}

/// Display facts only. No persisted data or reducer state is changed by inspecting counts.
struct HandParticipantCounts: Identifiable {
    let id = UUID()
    var context: String
    var capacity: String
    var seated: String
    var dealt: String
    var notFolded: String
    var actionable: String
    var stateNote: String

    init(hand: HandRecord, snapshot: HandSnapshot, session: SessionRecord?, context: String) {
        self.context = context
        capacity = (5...9).contains(hand.configuration.tableCapacity) ? "\(hand.configuration.tableCapacity) 个座位" : "待核对"
        seated = Self.seatedAtDeal(hand: hand, session: session)
        let validRoster = Set(hand.players.map(\.id)).count == hand.players.count &&
            Set(snapshot.players.map(\.id)) == Set(hand.players.map(\.id)) &&
            snapshot.players.count == hand.players.count
        dealt = Set(hand.players.map(\.id)).count == hand.players.count ? "\(hand.players.count) 人" : "待核对"
        guard validRoster, !snapshot.blocked else {
            notFolded = "待核对"; actionable = "待核对"
            stateNote = "此时点有缺项或冲突，不能从保留的旧状态推定精确人数。"
            return
        }
        let remaining = snapshot.players.filter { !$0.folded }
        notFolded = "\(remaining.count) 人"
        if snapshot.handComplete {
            actionable = "0 人"
            stateNote = "此时点已无后续行动。未弃牌仍保留全下玩家及底池资格。"
            return
        }
        guard snapshot.forcedContributionsComplete else {
            actionable = "待确认"
            stateNote = "强制投入尚未记录完整，暂不推定本街待决策人数。"
            return
        }
        let uncertain = remaining.filter { $0.remaining.certainty != .exact || $0.remaining.units == nil || $0.streetContribution.certainty != .exact || $0.streetContribution.units == nil }
        guard uncertain.isEmpty else {
            actionable = "待确认"
            stateNote = "\(uncertain.count) 位未弃牌玩家的筹码或投入为未知/近似，不能推定其是否还能行动。"
            return
        }
        if snapshot.roundComplete {
            actionable = "0 人"
            stateNote = snapshot.street == .river
                ? "此时点已无后续行动。未弃牌仍保留全下玩家及底池资格。"
                : "本街已无待决策玩家；仍有筹码不表示本街还需行动，下一街另行计算。"
            return
        }
        let active = remaining.filter { !$0.allIn && ($0.remaining.units ?? 0) > 0 }
        let needDecision = active.filter { player in
            let target = active.count <= 1
                ? min(snapshot.currentBet, remaining.filter { $0.id != player.id }.compactMap { $0.streetContribution.units }.max() ?? 0)
                : snapshot.currentBet
            return (player.streetContribution.units ?? 0) < target || (active.count > 1 && player.lastActedAt == nil)
        }
        actionable = "\(needDecision.count) 人"
        stateNote = "可行动指本街仍需决策的玩家，不仅是当前下一位行动者；已弃牌、全下及本街已完成决策者不计入。后续加注可能使已行动者再次需要决策。"
    }

    /// Personnel facts take effect only at hand boundaries. Financial events cannot change seating.
    private static func seatedAtDeal(hand: HandRecord, session: SessionRecord?) -> String {
        guard let session else { return "未记录" }
        guard session.ruleApplicabilityIssue == nil, hand.ruleApplicabilityIssue == nil,
              let reference = session.hands.first(where: { $0.handID == hand.id }), reference.number > 0,
              session.hands.filter({ $0.handID == hand.id }).count == 1,
              Set(session.hands.map(\.number)).count == session.hands.count,
              Set(session.hands.map(\.handID)).count == session.hands.count,
              Set(session.players.map(\.id)).count == session.players.count,
              Set(session.initialSeats.map(\.playerID)).count == session.initialSeats.count else { return "待核对" }
        var configuration = session.initialConfiguration
        var identities = session.players
        var seats = session.initialSeats
        var finance: [SessionFinanceEntry] = []
        let events = session.events.filter { $0.cancelledAt == nil }
        guard events.allSatisfy({ $0.effectiveHandNumber > 0 && $0.effectiveHandNumber <= session.nextHandNumber }),
              (1...reference.number).allSatisfy({ number in session.hands.contains { $0.number == number } }) else { return "待核对" }
        for number in 1...reference.number {
            for event in events where event.effectiveHandNumber == number {
                switch event.kind {
                case .buyIn, .topUp, .cashOut, .calibrate: continue
                default:
                    do { try SessionReducer.apply(event, configuration: &configuration, identities: &identities, seats: &seats, finance: &finance) }
                    catch { return "待核对" }
                }
            }
        }
        let occupied = seats.filter { $0.participation != .left }
        let dealtSeats = seats.filter { $0.participation == .playing }
        guard (5...9).contains(configuration.tableCapacity), configuration.tableCapacity == hand.configuration.tableCapacity,
              Set(occupied.map(\.seat)).count == occupied.count,
              occupied.allSatisfy({ seat in (0..<configuration.tableCapacity).contains(seat.seat) && identities.contains(where: { $0.id == seat.playerID }) }),
              Set(dealtSeats.map(\.playerID)) == Set(hand.players.map(\.id)),
              dealtSeats.count == hand.players.count,
              hand.players.allSatisfy({ player in dealtSeats.contains { $0.playerID == player.id && $0.seat == player.seat } }) else { return "待核对" }
        return "\(occupied.count) 人"
    }
}

struct HandParticipantCountsView: View {
    let counts: HandParticipantCounts
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("桌容量", value: counts.capacity)
                    LabeledContent("入座人数 · 本手开局", value: counts.seated)
                    LabeledContent("本手发牌人数", value: counts.dealt)
                } footer: {
                    Text("入座含暂离与等待者，不含已离桌者；只使用该手生效的场次名单。独立历史没有入座记录时显示未记录。")
                }
                Section {
                    LabeledContent("未弃牌人数", value: counts.notFolded)
                    LabeledContent("可行动人数 · 本街待决策", value: counts.actionable)
                    Text(counts.stateNote).font(.footnote).foregroundStyle(HandStyle.muted)
                } header: { Text(counts.context) } footer: {
                    Text("未弃牌包含全下玩家；玩家聚焦只筛选展示，人数始终按完整牌局计算。")
                }
            }.navigationTitle("人数与状态").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

private func participationLabel(_ value: SessionParticipation) -> String {
    switch value { case .playing: "参与"; case .sittingOut: "暂离"; case .waiting: "等待"; case .left: "离桌" }
}
private func sessionEventLabel(_ kind: SessionEventKind, identities: [SessionPlayer], unit: ChipUnit) -> String {
    func name(_ id: UUID) -> String { identities.first { $0.id == id }?.name ?? "未知玩家" }
    switch kind {
    case .join(let player, let seat): return "\(player.name) 加入座位 \(seat + 1)"
    case .leave(let id): return "\(name(id)) 离桌"
    case .sitOut(let id): return "\(name(id)) 暂离"
    case .returnToTable(let id, let play): return "\(name(id)) 返回 · \(play ? "参与" : "等待")"
    case .moveSeat(let id, let seat): return "\(name(id)) 移至座位 \(seat + 1)"
    case .swapSeats(let first, let second): return "\(name(first)) 与 \(name(second)) 换座"
    case .replaceIdentity(let old, let player): return "\(name(old)) 被新玩家 \(player.name) 替换"
    case .buyIn(let id, let amount): return "\(name(id)) 买入 \(unit.format(amount))"
    case .topUp(let id, let amount): return "\(name(id)) 补码 \(unit.format(amount))"
    case .cashOut(let id, let amount): return "\(name(id)) 带走 \(unit.format(amount))"
    case .calibrate(let id, let amount): return "\(name(id)) 实测校准为 \(unit.format(amount))"
    case .rules(let small, let big, let ante):
        var parts: [String] = []
        if let small { parts.append("SB \(unit.format(units: small))") }
        if let big { parts.append("BB \(unit.format(units: big))") }
        if ante != nil { parts.append("Ante 变更") }
        return "规则变更 · " + parts.joined(separator: " / ")
    }
}

private struct SessionManagementView: View {
    let sessionID: UUID
    @ObservedObject var store: LocalStore
    @Environment(\.dismiss) private var dismiss
    @State private var operation = "topup"
    @State private var playerID: UUID?
    @State private var secondID: UUID?
    @State private var seat = 0
    @State private var name = ""
    @State private var amount = ""
    @State private var smallBlind = ""
    @State private var bigBlind = ""
    @State private var anteType = "none"
    @State private var anteAmount = ""
    @State private var note = ""
    @State private var error: String?
    @FocusState private var focused: Bool
    private var session: SessionRecord? { store.sessions.first { $0.id == sessionID } }
    private let operations = [("topup", "补码"), ("calibrate", "实测校准"), ("cashout", "带走筹码"), ("buyin", "买入 / 重买"), ("join", "空座加入"), ("replace", "更换玩家身份"), ("leave", "离桌"), ("sitout", "暂离"), ("return", "返回并参与"), ("wait", "返回并等待"), ("move", "移至空座"), ("swap", "双方换座"), ("rules", "下一手盲注与前注")]
    var body: some View {
        NavigationStack {
            if let session {
                let preview = SessionReducer.previewNextHand(session, hands: store.hands, allowIncompleteResult: true)
                Form {
                    Section {
                        Picker("变更类型", selection: $operation) {
                            ForEach(operations, id: \.0) { key, label in Text(label).tag(key) }
                        }
                        if operation != "join" && operation != "rules" {
                            Picker("玩家", selection: $playerID) {
                                ForEach(preview.identities) { player in Text(player.name).tag(Optional(player.id)) }
                            }
                        }
                        if operation == "swap" {
                            Picker("另一位玩家", selection: $secondID) {
                                Text("请选择").tag(Optional<UUID>.none)
                                ForEach(preview.identities.filter { $0.id != playerID }) { player in Text(player.name).tag(Optional(player.id)) }
                            }
                        }
                        if operation == "join" || operation == "replace" { TextField("新玩家姓名", text: $name).focused($focused) }
                        if operation == "join" || operation == "move" {
                            Picker("目标座位", selection: $seat) {
                                ForEach(0..<preview.configuration.tableCapacity, id: \.self) { number in
                                    Text("座位 \(number + 1)" + (preview.seats.contains { $0.seat == number && $0.participation != .left } ? " · 已占用" : " · 空闲")).tag(number)
                                }
                            }
                        }
                        if ["topup", "cashout", "calibrate", "buyin", "join", "replace"].contains(operation) {
                            TextField(operation == "calibrate" ? "实测总余额（筹码）" : "金额（筹码）", text: $amount)
                                .keyboardType(.decimalPad).focused($focused)
                            Text(operation == "calibrate" ? "记录独立校准事件，不计作上一手输赢。" : "金额单独记入资金账；未知余额加补码后仍保持未知，不能代替实测校准。")
                                .font(.footnote).foregroundStyle(HandStyle.muted)
                        }
                        if operation == "rules" {
                            amountField("小盲 · SB", text: $smallBlind)
                            amountField("大盲 · BB", text: $bigBlind)
                            Picker("前注", selection: $anteType) {
                                Text("无").tag("none"); Text("每位玩家").tag("each"); Text("大盲支付").tag("bb"); Text("按钮支付").tag("button")
                            }
                            if anteType != "none" { amountField("前注金额", text: $anteAmount) }
                        }
                        TextField("备注（可选）", text: $note, axis: .vertical).focused($focused)
                    } header: { Text("第 \(session.nextHandNumber) 手生效") } footer: {
                        Text("当前已发牌的一手保持原名单与规则。离桌不会自动带走筹码；需要时另记资金事件。新身份不会继承旧玩家统计。")
                    }
                    if let error { Section { Text(error).foregroundStyle(HandStyle.red) } }
                    Section { Button("保存待生效变更") { save(preview) } }
                }
                .scrollContentBackground(.hidden).background(HandStyle.canvas)
                .scrollDismissesKeyboard(.interactively)
                .task {
                    playerID = preview.identities.first?.id
                    smallBlind = preview.configuration.chipUnit.format(units: preview.configuration.smallBlind)
                    bigBlind = preview.configuration.chipUnit.format(units: preview.configuration.bigBlind)
                    switch preview.configuration.ante {
                    case .none: anteType = "none"
                    case .perPlayer(let n): anteType = "each"; anteAmount = preview.configuration.chipUnit.format(units: n)
                    case .bigBlind(let n): anteType = "bb"; anteAmount = preview.configuration.chipUnit.format(units: n)
                    case .button(let n): anteType = "button"; anteAmount = preview.configuration.chipUnit.format(units: n)
                    }
                }
                .navigationTitle("场次管理").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { save(preview) } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成输入") { focused = false } }
                }
            }
        }.tint(HandStyle.green)
    }
    private func amountField(_ label: String, text: Binding<String>) -> some View {
        HStack { Text(label); TextField(label, text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($focused) }
    }
    private func save(_ preview: SessionNextHandPreview) {
        guard var session else { return }
        focused = false; error = nil
        do {
            var kinds: [SessionEventKind] = []
            let unit = preview.configuration.chipUnit
            func parse(_ value: String) throws -> ChipAmount {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
                      let result = unit.parse(trimmed) else { throw SessionError.invalid("请输入非负金额，且为最小筹码单位 \(unit.decimal) 的整数倍。") }
                return result
            }
            func actor() throws -> UUID {
                guard let playerID else { throw SessionError.invalid("请先选择玩家。") }; return playerID
            }
            switch operation {
            case "topup": kinds = [.topUp(playerID: try actor(), amount: try parse(amount))]
            case "cashout": kinds = [.cashOut(playerID: try actor(), amount: try parse(amount))]
            case "calibrate": kinds = [.calibrate(playerID: try actor(), measuredBalance: try parse(amount))]
            case "buyin": kinds = [.buyIn(playerID: try actor(), amount: try parse(amount))]
            case "leave": kinds = [.leave(playerID: try actor())]
            case "sitout": kinds = [.sitOut(playerID: try actor())]
            case "return": kinds = [.returnToTable(playerID: try actor(), participate: true)]
            case "wait": kinds = [.returnToTable(playerID: try actor(), participate: false)]
            case "move": kinds = [.moveSeat(playerID: try actor(), seat: seat)]
            case "swap":
                guard let secondID else { throw SessionError.invalid("请选择另一位玩家。") }
                kinds = [.swapSeats(first: try actor(), second: secondID)]
            case "join", "replace":
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw SessionError.invalid("请输入新玩家姓名。") }
                let player = SessionPlayer(name: trimmed)
                kinds = operation == "join" ? [.join(player: player, seat: seat)] : [.replaceIdentity(oldPlayerID: try actor(), newPlayer: player)]
                kinds.append(.buyIn(playerID: player.id, amount: try parse(amount)))
            case "rules":
                guard let sb = try parse(smallBlind).units, let bb = try parse(bigBlind).units, sb > 0, bb > 0 else { throw SessionError.invalid("小盲、大盲须分别大于零。") }
                let ante: AnteRule
                if anteType == "none" { ante = .none }
                else {
                    guard let value = try parse(anteAmount).units else { throw SessionError.invalid("前注金额无效。") }
                    switch anteType { case "each": ante = .perPlayer(value); case "bb": ante = .bigBlind(value); default: ante = .button(value) }
                }
                kinds = [.rules(smallBlind: sb == preview.configuration.smallBlind ? nil : sb,
                    bigBlind: bb == preview.configuration.bigBlind ? nil : bb, ante: ante == preview.configuration.ante ? nil : ante)]
            default: return
            }
            try SessionReducer.queue(kinds, in: &session, hands: store.hands, note: note)
            try store.upsertSession(session); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct SessionPlayerView: View {
    let sessionID: UUID
    let playerID: UUID
    @ObservedObject var store: LocalStore
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var error: String?
    private var session: SessionRecord? { store.sessions.first { $0.id == sessionID } }
    var body: some View {
        NavigationStack {
            if let session {
                let preview = SessionReducer.previewNextHand(session, hands: store.hands, allowIncompleteResult: true)
                let player = preview.identities.first { $0.id == playerID }
                let stats = SessionReducer.statistics(session, hands: store.hands, playerID: playerID)
                Form {
                    Section("本场次样本") {
                        LabeledContent("发牌手数", value: "\(stats.dealtHands)")
                        metric("VPIP", value: stats.vpip)
                        metric("PFR", value: stats.pfr)
                        metric("3-bet", value: stats.threeBet)
                    }
                    Section("已确认结算") {
                        LabeledContent("有效 / 待核对", value: "\(stats.settledHands) / \(stats.unsettledHands)")
                        LabeledContent("牌局净结果", value: stats.settledHands == 0 ? "待结算" : preview.configuration.chipUnit.format(stats.pokerNet))
                        LabeledContent("BB 净结果", value: stats.settledHands == 0 ? "待结算" : String(format: "%.2f BB", stats.bigBlindNet))
                        Text("仅合计有效结算；不包括买入、补码、带走与实测校准。").font(.footnote).foregroundStyle(HandStyle.muted)
                    }
                    if !stats.exclusions.isEmpty {
                        Section("统计排除原因") {
                            ForEach(Array(stats.exclusions.enumerated()), id: \.offset) { _, reason in Text(reason).font(.footnote) }
                        }
                    }
                    Section("玩家笔记") { TextField("记录观察与疑问", text: $notes, axis: .vertical).lineLimit(5...12) }
                    if let error { Section { Text(error).foregroundStyle(HandStyle.red) } }
                }
                .scrollContentBackground(.hidden).background(HandStyle.canvas)
                .navigationTitle(player?.name ?? "玩家").navigationBarTitleDisplayMode(.inline)
                .task { notes = player?.notes ?? "" }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存笔记") { saveNotes() } }
                }
            }
        }.tint(HandStyle.green)
    }
    private func metric(_ title: String, value: SessionMetric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: value.percent.map { String(format: "%.1f%%", $0) } ?? "样本不足")
            Text("\(value.count) 次 / \(value.opportunities) 次机会 · 排除 \(value.excludedHands) 手")
                .font(.caption).foregroundStyle(HandStyle.muted)
        }
    }
    private func saveNotes() {
        guard var session else { return }
        if let index = session.players.firstIndex(where: { $0.id == playerID }) { session.players[index].notes = notes }
        else {
            for index in session.events.indices {
                switch session.events[index].kind {
                case .join(var player, let seat) where player.id == playerID:
                    player.notes = notes; session.events[index].kind = .join(player: player, seat: seat)
                case .replaceIdentity(let old, var player) where player.id == playerID:
                    player.notes = notes; session.events[index].kind = .replaceIdentity(oldPlayerID: old, newPlayer: player)
                default: break
                }
            }
        }
        session.updatedAt = Date()
        do { try store.upsertSession(session); dismiss() } catch { self.error = error.localizedDescription }
    }
}
