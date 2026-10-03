import SwiftUI

struct SessionCorrectionRepairScreen: View {
    /// Frozen inputs keep every subsequent repair and final confirmation on one version guard.
    let session: SessionRecord
    let hands: [HandRecord]
    let eventID: UUID
    let replacement: SessionEventKind
    let effectiveHandNumber: Int
    let relatedEffectiveHandNumbers: [UUID: Int]
    @ObservedObject var store: LocalStore
    let onCommitted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var resolutions: [UUID: SessionHandFactResolution] = [:]
    @State private var requirements: [UUID: SessionHandRepairRequirement] = [:]
    @State private var preview: SessionCorrectionPreview?
    @State private var editing: SessionHandRepairRequirement?
    @State private var showPreview = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("逐手核对实际发生的事实").font(.headline)
                    Text("人员更正已改变手牌名单或原行动的合法性。逐位确认底牌，逐条保留、更正或移除原事件；这些操作暂存在本次更正中。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let preview {
                    SessionCorrectionEventChangesSection(impacts: preview.eventImpacts, session: session)
                    ForEach(preview.requiredRepairs) { requirement in
                        Section("第 \(requirement.number) 手 · 待修正") {
                            ForEach(Array(requirement.reasons.enumerated()), id: \.offset) { _, reason in Text(reason).font(.footnote).foregroundStyle(.orange) }
                            Text("实际发牌：" + requirement.players.sorted { $0.seat < $1.seat }.map(\.name).joined(separator: "、"))
                            Button("明确修正第 \(requirement.number) 手") { editing = requirement }
                        }
                    }
                    ForEach(session.hands.filter { reference in resolutions[reference.handID] != nil && !preview.requiredRepairs.contains(where: { $0.id == reference.handID }) }) { reference in
                        Section("第 \(reference.number) 手 · 已核对") {
                            Text("名单、底牌和原事件已逐项确认").foregroundStyle(.secondary)
                            Button("重新核对") { editing = requirements[reference.handID] }
                        }
                    }
                    if preview.requiredRepairs.isEmpty && !preview.conflicts.isEmpty {
                        Section("需要调整的来源") {
                            ForEach(Array(preview.conflicts.enumerated()), id: \.offset) { _, message in Text(message).foregroundStyle(.red) }
                        }
                    }
                    Section {
                        Button("查看整条更正预览") { showPreview = true }.disabled(!preview.canCommit)
                        Text("只有全部受影响手牌核对完成后才可提交。确认时还会重新检查整个场次和手牌是否已改变。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("逐手修正").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消本次更正") { dismiss() } } }
            .task { if preview == nil { rebuild() } }
            .sheet(item: $editing) { requirement in
                SessionCorrectionHandEditor(requirement: requirement, existing: resolutions[requirement.id]) { resolution in
                    resolutions[requirement.id] = resolution
                    editing = nil
                    rebuild()
                }
            }
            .sheet(isPresented: $showPreview) {
                if let preview {
                    SessionCorrectionView(preview: preview, store: store) { onCommitted(); dismiss() }
                }
            }
        }.tint(HandStyle.green)
    }
    private func rebuild() {
        let updated = store.previewSessionCorrection(session, hands: hands,
            request: .event(eventID: eventID, replacement: replacement, effectiveHandNumber: effectiveHandNumber,
                            resolutions: session.hands.compactMap { resolutions[$0.handID] }, relatedEffectiveHandNumbers: relatedEffectiveHandNumbers))
        for requirement in updated.requiredRepairs { requirements[requirement.id] = requirement }
        preview = updated
    }
}

private struct CorrectionActionRoute: Identifiable {
    let id = UUID()
    let event: HandEvent?
    let insertionIndex: Int
}
private struct CorrectionCardRoute: Identifiable {
    let id = UUID()
    let playerID: UUID?
    let eventID: UUID?
    let count: Int
    let initial: [PokerCard]
}

struct SessionCorrectionHandEditor: View {
    let requirement: SessionHandRepairRequirement
    let existing: SessionHandFactResolution?
    let finish: (SessionHandFactResolution) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HandRecord?
    @State private var reviewedPlayers: Set<UUID> = []
    @State private var reviewedEvents: Set<UUID> = []
    @State private var confirmResult = false
    @State private var selections: [Int: SettlementSelection] = [:]
    @State private var actionRoute: CorrectionActionRoute?
    @State private var cardRoute: CorrectionCardRoute?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let draft {
                    participantsSection(draft)
                    eventsSection(draft)
                    resultSection(draft)
                    let issues = HandReducer.project(draft).issues
                    if !issues.isEmpty {
                        Section("需修正的行动") { ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in Text(issue.message).foregroundStyle(.orange) } }
                    }
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                    Section { Button("确认本手修正，返回整条核对") { save() } }
                }
            }
            .navigationTitle("第 \(requirement.number) 手事实").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消本手修改") { dismiss() } } }
            .task { if draft == nil { load() } }
            .sheet(item: $actionRoute) { route in
                if let draft {
                    ActionEntryScreen(hand: draft, editing: route.event, insertionIndex: route.insertionIndex, allowIncomplete: true) { event in
                        if let event {
                            if let index = self.draft?.events.firstIndex(where: { $0.id == event.id }) { self.draft?.events[index] = event }
                            else { self.draft?.events.insert(event, at: min(route.insertionIndex, self.draft?.events.count ?? 0)) }
                            reviewedEvents.insert(event.id); selections = [:]
                        }
                        actionRoute = nil
                    }
                }
            }
            .sheet(item: $cardRoute) { route in
                if let draft {
                    let used = Set(draft.players.filter { $0.id != route.playerID }.flatMap(\.holeCards) + draft.events.filter { $0.id != route.eventID }.flatMap(\.cards))
                    CardEntryScreen(title: route.playerID == nil ? "更正公共牌" : "核对实际底牌", count: route.count, initial: route.initial, used: used) { cards in
                        if let cards { updateCards(cards, playerID: route.playerID, eventID: route.eventID) }
                        cardRoute = nil
                    }
                }
            }
        }.tint(HandStyle.green)
    }

    private func participantsSection(_ draft: HandRecord) -> some View {
        Section("本手参与名单") {
            Text("起始筹码来自已更正的前手结果及独立资金事件；金额未知时保留待核对。名单由人员事件确定。")
                .font(.footnote).foregroundStyle(.secondary)
            Picker("本手按钮 · BTN", selection: Binding(get: { draft.configuration.buttonSeat }, set: { seat in self.draft?.configuration.buttonSeat = seat; reviewedEvents.removeAll() })) {
                ForEach(draft.players) { player in Text("\(player.name) · 座位 \(player.seat + 1)").tag(player.seat) }
            }
            ForEach(draft.players) { player in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(player.name) · 座位 \(player.seat + 1)").font(.subheadline.weight(.semibold))
                    Text("起始 \(draft.configuration.chipUnit.format(player.startingStack)) · 底牌 \(cardsText(player.holeCards))")
                        .font(.footnote)
                    HStack {
                        Button("录入或更正底牌") { cardRoute = .init(playerID: player.id, eventID: nil, count: 2, initial: player.holeCards) }
                        if !player.holeCards.isEmpty { Button("设为未知") { updateCards([], playerID: player.id, eventID: nil) } }
                    }.buttonStyle(.borderless)
                    Toggle("确认该身份参与且底牌归属正确", isOn: reviewedPlayerBinding(player.id))
                        .accessibilityLabel("第 \(requirement.number) 手，\(player.name)，座位 \(player.seat + 1)，确认该身份参与且底牌归属正确")
                        .accessibilityIdentifier("session-correction.\(requirement.id).participant.\(player.id)")
                }.padding(.vertical, 4)
            }
            ForEach(requirement.original.players.filter { old in !draft.players.contains(where: { $0.id == old.id }) }) { old in
                VStack(alignment: .leading) {
                    Text("\(old.name) · 更正后未发牌").font(.subheadline.weight(.semibold))
                    Text("原底牌：\(cardsText(old.holeCards))；保留在旧档，不交给其他身份。").font(.footnote).foregroundStyle(.secondary)
                    Toggle("确认本手不属于这位玩家", isOn: reviewedPlayerBinding(old.id))
                        .accessibilityLabel("第 \(requirement.number) 手，\(old.name)，原座位 \(old.seat + 1)，确认本手不属于这位玩家")
                        .accessibilityIdentifier("session-correction.\(requirement.id).excluded-participant.\(old.id)")
                }
            }
        }
    }

    private func eventsSection(_ draft: HandRecord) -> some View {
        Section {
            ForEach(Array(draft.events.enumerated()), id: \.element.id) { index, event in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(index + 1). \(event.street.title) · \(eventName(event, hand: draft))").font(.subheadline.weight(.semibold))
                    if let original = requirement.original.events.first(where: { $0.id == event.id }), original != event {
                        Text("原记录：\(eventName(original, hand: requirement.original))").font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("确认此事件及实际玩家归属", isOn: reviewedEventBinding(event.id))
                        .accessibilityLabel(eventConfirmationLabel(event, index: index, hand: draft))
                        .accessibilityIdentifier("session-correction.\(requirement.id).event.\(event.id)")
                    HStack {
                        Button("更正") {
                            if event.kind == .deal { cardRoute = .init(playerID: nil, eventID: event.id, count: event.street.cardCount, initial: event.cards) }
                            else { actionRoute = .init(event: event, insertionIndex: index) }
                        }
                        Button("移除") { remove(event.id) }
                        if index > 0 { Button("上移") { move(index, to: index - 1) } }
                        if index + 1 < draft.events.count { Button("下移") { move(index, to: index + 1) } }
                    }.buttonStyle(.borderless)
                    insertionMenu(index, draft: draft)
                }.padding(.vertical, 5)
            }
            ForEach(requirement.original.events.filter { old in !draft.events.contains(where: { $0.id == old.id }) }) { old in
                VStack(alignment: .leading) {
                    Text("已明确移除：\(eventName(old, hand: requirement.original))").font(.footnote).foregroundStyle(.secondary)
                    Button("恢复原事件") {
                        let index = min(requirement.original.events.firstIndex(where: { $0.id == old.id }) ?? draft.events.count, draft.events.count)
                        self.draft?.events.insert(old, at: index); reviewedEvents.remove(old.id)
                    }
                }
            }
            insertionMenu(draft.events.count, draft: draft)
        } header: {
            Text("逐条确认实际事件")
        } footer: {
            Text("移除或修改只作用于本次更正；原事件和金额完整归档。不会自动把移除玩家的下注交给其他身份。")
        }
    }

    private func load() {
        var record = existing?.hand ?? requirement.original
        record.configuration = requirement.configuration
        if let existing { record.configuration.buttonSeat = existing.hand.configuration.buttonSeat }
        record.players = requirement.players.map { expected in
            var player = expected
            if let previous = existing?.hand.players.first(where: { $0.id == expected.id }) { player.holeCards = previous.holeCards }
            return player
        }
        record.settlement = nil; record.settlementHistory = nil
        draft = record
        if let existing {
            reviewedPlayers = existing.reviewedPlayerIDs
            reviewedEvents = existing.reviewedEventIDs
            selections = existing.settlementSelections ?? [:]
            confirmResult = existing.settlementSelections != nil
        }
    }
    private func reviewedPlayerBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { reviewedPlayers.contains(id) }, set: { if $0 { reviewedPlayers.insert(id) } else { reviewedPlayers.remove(id) } })
    }
    private func reviewedEventBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { reviewedEvents.contains(id) }, set: { if $0 { reviewedEvents.insert(id) } else { reviewedEvents.remove(id) } })
    }
    private func updateCards(_ cards: [PokerCard], playerID: UUID?, eventID: UUID?) {
        if let playerID, let index = draft?.players.firstIndex(where: { $0.id == playerID }) { draft?.players[index].holeCards = cards; reviewedPlayers.remove(playerID) }
        if let eventID, let index = draft?.events.firstIndex(where: { $0.id == eventID }) { draft?.events[index].cards = cards; reviewedEvents.insert(eventID) }
        selections = [:]
    }
    private func remove(_ id: UUID) { draft?.events.removeAll { $0.id == id }; reviewedEvents.insert(id); selections = [:] }
    private func move(_ index: Int, to target: Int) {
        guard var value = draft else { return }
        reviewedEvents.remove(value.events[index].id); reviewedEvents.remove(value.events[target].id)
        value.events.swapAt(index, target); draft = value; selections = [:]
    }
    private func eventName(_ event: HandEvent, hand: HandRecord) -> String {
        if event.kind == .deal { return "公共牌 " + cardsText(event.cards) }
        let name = hand.players.first { $0.id == event.playerID }?.name
            ?? requirement.original.players.first { $0.id == event.playerID }?.name ?? "未指定身份"
        return name + " · " + event.kind.title + (event.amount.map { " " + hand.configuration.chipUnit.format($0) } ?? "")
    }
    private func eventConfirmationLabel(_ event: HandEvent, index: Int, hand: HandRecord) -> String {
        let origin = requirement.original.events.firstIndex(where: { $0.id == event.id })
            .map { "原事件 \($0 + 1)" } ?? "补录事件"
        let player = hand.players.first { $0.id == event.playerID }
            ?? requirement.original.players.first { $0.id == event.playerID }
        let seat = player.map { "，座位 \($0.seat + 1)" } ?? ""
        return "第 \(requirement.number) 手，\(origin)，当前第 \(index + 1) 条，\(event.street.title)，\(eventName(event, hand: hand))\(seat)，确认此事件及实际玩家归属"
    }
    private func cardsText(_ cards: [PokerCard]) -> String { cards.isEmpty ? "未知" : cards.map(\.label).joined(separator: " ") }
    private func insertionMenu(_ index: Int, draft: HandRecord) -> some View {
        Menu(index == draft.events.count ? "在末尾补录" : "在此事件前补录") {
            Button("实际行动") { actionRoute = .init(event: nil, insertionIndex: index) }
            ForEach([HandEventKind.smallBlind, .bigBlind, .ante], id: \.self) { kind in
                Button(kind.title) {
                    actionRoute = .init(event: .init(street: .preflop, playerID: draft.players.first?.id, kind: kind, amount: .unknown, source: "历史更正补录"), insertionIndex: index)
                }
            }
            ForEach([HandStreet.flop, .turn, .river], id: \.self) { street in
                Button("\(street.title)公共牌") {
                    let event = HandEvent(street: street, kind: .deal, source: "历史更正补录")
                    self.draft?.events.insert(event, at: min(index, self.draft?.events.count ?? 0))
                    cardRoute = .init(playerID: nil, eventID: event.id, count: street.cardCount, initial: [])
                }
            }
        }.buttonStyle(.borderless)
    }
    @ViewBuilder
    private func resultSection(_ hand: HandRecord) -> some View {
        Section("本手结果") {
            Toggle("结果已知，重新核对结算", isOn: $confirmResult)
            if confirmResult {
                let preview = HandSettlement.preview(hand, selections: selections)
                ForEach(preview.pots) { pot in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("第 \(pot.id + 1) 池 · \(hand.configuration.chipUnit.format(units: pot.units))").font(.subheadline.weight(.semibold))
                        ForEach(hand.players.filter { pot.eligibleIDs.contains($0.id) }) { player in
                            Toggle("赢家 · \(player.name)", isOn: Binding(get: {
                                (selections[pot.id]?.winnerIDs ?? pot.winnerIDs).contains(player.id)
                            }, set: { selected in
                                var ids = selections[pot.id]?.winnerIDs ?? pot.winnerIDs
                                ids.removeAll { $0 == player.id }; if selected { ids.append(player.id) }
                                selections[pot.id] = .init(winnerIDs: ids, oddChipFirst: nil)
                            }))
                        }
                        let winners = selections[pot.id]?.winnerIDs ?? pot.winnerIDs
                        if winners.count > 1 {
                            Picker("零头起点", selection: Binding(get: { selections[pot.id]?.oddChipFirst }, set: { id in selections[pot.id] = .init(winnerIDs: winners, oddChipFirst: id) })) {
                                Text("按钮后顺时针").tag(Optional<UUID>.none)
                                ForEach(hand.players.filter { winners.contains($0.id) }) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    }
                }
                ForEach(Array(preview.issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.footnote).foregroundStyle(.orange) }
            } else {
                Text("原结果仅保留在旧档。本手结束余额及依赖它的下手余额标待核对，不能冒充已结算盈亏。").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private func save() {
        guard let draft else { return }
        let allPlayers = Set(requirement.original.players.map(\.id)).union(requirement.players.map(\.id))
        guard allPlayers.isSubset(of: reviewedPlayers) else { error = "请逐位确认参与身份与底牌归属。"; return }
        let allEvents = Set(requirement.original.events.map(\.id)).union(draft.events.map(\.id))
        guard allEvents.isSubset(of: reviewedEvents) else { error = "请逐条确认实际事件，包括新增事件。"; return }
        let issues = HandReducer.project(draft).issues
        guard issues.isEmpty else { error = "请先修正所列行动顺序、金额或牌张冲突。"; return }
        if confirmResult {
            let result = HandSettlement.preview(draft, selections: selections)
            guard result.canConfirm else { error = result.issues.joined(separator: "；"); return }
        }
        finish(.init(hand: draft, reviewedPlayerIDs: reviewedPlayers, reviewedEventIDs: reviewedEvents, settlementSelections: confirmResult ? selections : nil))
    }
}
