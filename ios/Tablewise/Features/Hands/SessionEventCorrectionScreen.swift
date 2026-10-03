import SwiftUI

private struct EventCorrectionPreviewRoute: Identifiable {
    let id = UUID()
    let preview: SessionCorrectionPreview
    let session: SessionRecord
    let hands: [HandRecord]
    let eventID: UUID
    let replacement: SessionEventKind
    let effectiveNumber: Int
    let relatedEffectiveHandNumbers: [UUID: Int]
}

struct SessionEventCorrectionScreen: View {
    let sessionID: UUID
    let eventID: UUID
    @ObservedObject var store: LocalStore
    @Environment(\.dismiss) private var dismiss
    @State private var relatedEffectiveHandNumbers: [UUID: Int] = [:]
    @State private var effectiveNumber = 1
    @State private var playerID: UUID?
    @State private var secondID: UUID?
    @State private var targetSeat = 0
    @State private var amount = ""
    @State private var participate = true
    @State private var changesSmallBlind = false
    @State private var changesBigBlind = false
    @State private var changesAnte = false
    @State private var smallBlind = ""
    @State private var bigBlind = ""
    @State private var anteType = "none"
    @State private var anteAmount = ""
    @State private var previewRoute: EventCorrectionPreviewRoute?
    @State private var error: String?
    @State private var loaded = false
    @FocusState private var focused: Bool
    private var session: SessionRecord? { store.sessions.first { $0.id == sessionID } }
    private var original: SessionEvent? { session?.events.first { $0.id == eventID } }

    var body: some View {
        NavigationStack {
            if let session, let original {
                let roster = SessionReducer.previewNextHand(session, hands: store.hands, allowIncompleteResult: true)
                Form {
                    Section {
                        Text("原事件 · \(kindLabel(original.kind))").font(.headline)
                        Text("原生效时间：第 \(original.effectiveHandNumber) 手前").font(.subheadline)
                        Text(original.id.uuidString).font(.caption2.monospaced()).textSelection(.enabled)
                        if !original.note.isEmpty { Text(original.note).font(.footnote).foregroundStyle(HandStyle.muted) }
                        Stepper("更正为第 \(effectiveNumber) 手前生效", value: $effectiveNumber, in: 1...session.nextHandNumber)
                    } footer: {
                        Text("这是对已生效事实的更正。下一步先预览受影响手牌、座位、筹码及结算，不会直接改写历史。")
                    }
                    relatedEventsSection(original, session: session)
                    Section("更正内容") {
                        eventFields(original.kind, identities: roster.identities, capacity: session.initialConfiguration.tableCapacity)
                    }
                    Section {
                        Text("涉及已发牌人员名单变化时，不自动把旧玩家行动交给新身份，也不删除原手。跨过实测筹码校准的衔接规则未确认时，预览会明确阻止提交。")
                            .font(.footnote).foregroundStyle(HandStyle.muted)
                    }
                    if let error { Section { Text(error).foregroundStyle(HandStyle.red) } }
                    Section { Button("预览全部影响") { preview() } }
                }
                .scrollContentBackground(.hidden).background(HandStyle.canvas).scrollDismissesKeyboard(.interactively)
                .navigationTitle("更正已生效事件").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("预览") { preview() } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成输入") { focused = false } }
                }
                .task { if !loaded { loaded = true; load(original, session: session) } }
                .sheet(item: $previewRoute) { route in
                    if route.preview.requiredRepairs.isEmpty {
                        SessionCorrectionView(preview: route.preview, store: store) { dismiss() }
                    } else {
                        SessionCorrectionRepairScreen(session: route.session, hands: route.hands, eventID: route.eventID,
                            replacement: route.replacement, effectiveHandNumber: route.effectiveNumber, relatedEffectiveHandNumbers: route.relatedEffectiveHandNumbers, store: store) { dismiss() }
                    }
                }
            } else { ContentUnavailableView("原事件不存在", systemImage: "exclamationmark.triangle") }
        }.tint(HandStyle.green)
    }
    @ViewBuilder
    private func relatedEventsSection(_ original: SessionEvent, session: SessionRecord) -> some View {
        let related = SessionReducer.relatedBoundaryEvents(to: original, in: session)
        if !related.isEmpty {
            Section {
                ForEach(related) { event in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(SessionCorrectionEventChangesSection.label(event.kind, session: session)).font(.subheadline)
                        Text("原生效：第 \(event.effectiveHandNumber) 手前").font(.footnote).foregroundStyle(.secondary)
                        Toggle("同时更正此事件的生效时间", isOn: Binding(get: {
                            relatedEffectiveHandNumbers[event.id] != nil
                        }, set: { selected in
                            if selected { relatedEffectiveHandNumbers[event.id] = event.effectiveHandNumber }
                            else { relatedEffectiveHandNumbers.removeValue(forKey: event.id) }
                        }))
                        if relatedEffectiveHandNumbers[event.id] != nil {
                            Stepper("更正为第 \(relatedEffectiveHandNumbers[event.id] ?? event.effectiveHandNumber) 手前生效", value: Binding(get: {
                                relatedEffectiveHandNumbers[event.id] ?? event.effectiveHandNumber
                            }, set: { relatedEffectiveHandNumbers[event.id] = $0 }), in: 1...session.nextHandNumber)
                        }
                    }
                }
            } header: {
                Text("关联身份与买入")
            } footer: {
                Text("逐项选择实际生效时间。未选择的事件保持原时间；关联事件只更正时间，身份和资金金额保持原记录。预览会列出每项旧时间与新时间。")
            }
        }
    }

    @ViewBuilder
    private func eventFields(_ kind: SessionEventKind, identities: [SessionPlayer], capacity: Int) -> some View {
        switch kind {
        case .join(let player, _):
            LabeledContent("加入身份", value: player.name)
            seatPicker(capacity)
        case .replaceIdentity(_, let player):
            playerPicker("被替换的原玩家", identities: identities, selection: $playerID)
            LabeledContent("新身份（保持不变）", value: player.name)
        case .moveSeat:
            playerPicker("玩家", identities: identities, selection: $playerID)
            seatPicker(capacity)
        case .swapSeats:
            playerPicker("第一位玩家", identities: identities, selection: $playerID)
            playerPicker("第二位玩家", identities: identities, selection: $secondID)
        case .leave, .sitOut:
            playerPicker("玩家", identities: identities, selection: $playerID)
        case .returnToTable:
            playerPicker("玩家", identities: identities, selection: $playerID)
            Toggle("返回后参与发牌", isOn: $participate)
        case .buyIn, .topUp, .cashOut, .calibrate:
            playerPicker("玩家", identities: identities, selection: $playerID)
            amountField("更正金额（筹码）", value: $amount)
            if case .calibrate = kind {
                Text("校准衔接规则仍待确认；可以查看阻断原因，不能绕过校准直接改写后续余额。")
                    .font(.footnote).foregroundStyle(HandStyle.gold)
            }
        case .rules:
            Toggle("此事件修改小盲", isOn: $changesSmallBlind)
            if changesSmallBlind { amountField("小盲 · SB", value: $smallBlind) }
            Toggle("此事件修改大盲", isOn: $changesBigBlind)
            if changesBigBlind { amountField("大盲 · BB", value: $bigBlind) }
            Toggle("此事件修改前注", isOn: $changesAnte)
            if changesAnte {
                Picker("前注", selection: $anteType) {
                    Text("无前注").tag("none"); Text("每位玩家").tag("each")
                    Text("大盲支付").tag("bb"); Text("按钮支付").tag("button")
                }
                if anteType != "none" { amountField("前注金额", value: $anteAmount) }
            }
            Text("关闭某项表示此事件不修改该项，沿用其前序规则；不代表金额为 0。")
                .font(.footnote).foregroundStyle(HandStyle.muted)
        }
    }
    private func playerPicker(_ title: String, identities: [SessionPlayer], selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            ForEach(identities) { person in Text(person.name).tag(Optional(person.id)) }
        }
    }
    private func seatPicker(_ capacity: Int) -> some View {
        Picker("实际座位", selection: $targetSeat) {
            ForEach(0..<capacity, id: \.self) { seat in Text("座位 \(seat + 1)").tag(seat) }
        }
    }
    private func amountField(_ title: String, value: Binding<String>) -> some View {
        HStack { Text(title); TextField("金额", text: value).keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($focused) }
    }
    private func load(_ event: SessionEvent, session: SessionRecord) {
        effectiveNumber = event.effectiveHandNumber
        let unit = session.initialConfiguration.chipUnit
        switch event.kind {
        case .join(_, let seat): targetSeat = seat
        case .replaceIdentity(let old, _): playerID = old
        case .moveSeat(let id, let seat): playerID = id; targetSeat = seat
        case .swapSeats(let first, let second): playerID = first; secondID = second
        case .leave(let id), .sitOut(let id): playerID = id
        case .returnToTable(let id, let play): playerID = id; participate = play
        case .buyIn(let id, let value), .topUp(let id, let value), .cashOut(let id, let value), .calibrate(let id, let value):
            playerID = id; amount = value.units.map { unit.format(units: $0) } ?? ""
        case .rules(let sb, let bb, let ante):
            changesSmallBlind = sb != nil; changesBigBlind = bb != nil; changesAnte = ante != nil
            smallBlind = sb.map { unit.format(units: $0) } ?? ""
            bigBlind = bb.map { unit.format(units: $0) } ?? ""
            if let ante {
                switch ante {
                case .none: anteType = "none"
                case .perPlayer(let n): anteType = "each"; anteAmount = unit.format(units: n)
                case .bigBlind(let n): anteType = "bb"; anteAmount = unit.format(units: n)
                case .button(let n): anteType = "button"; anteAmount = unit.format(units: n)
                }
            }
        }
    }
    private func preview() {
        guard let session, let original else { return }
        focused = false; error = nil
        do {
            func actor() throws -> UUID {
                guard let playerID else { throw SessionError.invalid("请选择实际玩家。") }; return playerID
            }
            func parse(_ value: String, positive: Bool = false) throws -> ChipAmount {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
                      let parsed = session.initialConfiguration.chipUnit.parse(trimmed), let units = parsed.units,
                      !positive || units > 0 else { throw SessionError.invalid("请填写符合最小筹码单位的\(positive ? "正数" : "非负")金额。") }
                return parsed
            }
            let replacement: SessionEventKind
            switch original.kind {
            case .join(let player, _): replacement = .join(player: player, seat: targetSeat)
            case .replaceIdentity(_, let new): replacement = .replaceIdentity(oldPlayerID: try actor(), newPlayer: new)
            case .leave: replacement = .leave(playerID: try actor())
            case .sitOut: replacement = .sitOut(playerID: try actor())
            case .returnToTable: replacement = .returnToTable(playerID: try actor(), participate: participate)
            case .moveSeat: replacement = .moveSeat(playerID: try actor(), seat: targetSeat)
            case .swapSeats:
                guard let secondID, secondID != playerID else { throw SessionError.invalid("换座需要两位不同玩家。") }
                replacement = .swapSeats(first: try actor(), second: secondID)
            case .buyIn: replacement = .buyIn(playerID: try actor(), amount: try parse(amount))
            case .topUp: replacement = .topUp(playerID: try actor(), amount: try parse(amount))
            case .cashOut: replacement = .cashOut(playerID: try actor(), amount: try parse(amount))
            case .calibrate: replacement = .calibrate(playerID: try actor(), measuredBalance: try parse(amount))
            case .rules:
                let sb = changesSmallBlind ? try parse(smallBlind, positive: true).units : nil
                let bb = changesBigBlind ? try parse(bigBlind, positive: true).units : nil
                var ante: AnteRule?
                if changesAnte {
                    if anteType == "none" { ante = AnteRule.none }
                    else {
                        let value = try parse(anteAmount).units ?? 0
                        switch anteType { case "each": ante = .perPlayer(value); case "bb": ante = .bigBlind(value); default: ante = .button(value) }
                    }
                }
                replacement = .rules(smallBlind: sb, bigBlind: bb, ante: ante)
            }
            let result = store.previewSessionCorrection(session,
                request: .event(eventID: original.id, replacement: replacement, effectiveHandNumber: effectiveNumber, relatedEffectiveHandNumbers: relatedEffectiveHandNumbers))
            previewRoute = EventCorrectionPreviewRoute(preview: result, session: session, hands: store.hands, eventID: original.id, replacement: replacement, effectiveNumber: effectiveNumber, relatedEffectiveHandNumbers: relatedEffectiveHandNumbers)
        } catch { self.error = error.localizedDescription }
    }
    private func kindLabel(_ kind: SessionEventKind) -> String {
        switch kind {
        case .join: "加入"; case .leave: "离桌"; case .sitOut: "暂离"; case .returnToTable: "返回"
        case .moveSeat: "移动座位"; case .swapSeats: "双方换座"; case .replaceIdentity: "身份替换"
        case .buyIn: "买入"; case .topUp: "补码"; case .cashOut: "带走筹码"; case .calibrate: "实测校准"; case .rules: "规则变更"
        }
    }
}
