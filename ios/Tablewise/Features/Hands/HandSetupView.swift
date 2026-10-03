import SwiftUI

struct HandSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LocalStore
    var editing: HandRecord? = nil
    var createSession = false
    var onCreated: (UUID) -> Void
    @State private var title = ""
    @State private var gameFormat: HandGameFormat? = nil
    @State private var count = 6
    @State private var heroSeat: Int? = 0
    @State private var buttonSeat = 5
    @State private var smallBlind = "1"
    @State private var bigBlind = "2"
    @State private var minimumUnit = "1"
    @State private var anteType = "none"
    @State private var anteAmount = "0"
    @State private var names = (1...9).map { "玩家 \($0)" }
    @State private var stacks = Array(repeating: "100", count: 9)
    @State private var certainties = Array(repeating: ValueCertainty.exact, count: 9)
    @State private var error: String?
    @FocusState private var isEditing: Bool
    @State private var loaded = false
    @State private var correctionPreview: HandRecord?

    private var hasRecordedEvents: Bool { !(editing?.events.isEmpty ?? true) }
    private var visibleSeats: [Int] {
        if let editing, hasRecordedEvents { return editing.players.map(\.seat).sorted() }
        return Array(0..<count)
    }
    private var noHeroLabel: String {
        guard let editing,
              let session = store.sessions.first(where: { session in session.hands.contains { $0.handID == editing.id } }),
              session.players.contains(where: { identity in identity.isHero && !editing.players.contains { $0.id == identity.id } }) else {
            return "未标记自己"
        }
        return "自己未参与本手"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(createSession ? "场次名称（可选）" : "牌局名称（可选）", text: $title).focused($isEditing)
                    if editing == nil && !store.hands.isEmpty {
                        Button("复用最近一手的桌面配置") { reuseConfiguration() }
                    }
                    if hasRecordedEvents {
                        LabeledContent("本手参与人数", value: "\(visibleSeats.count) 人")
                    } else {
                        Stepper("参与人数  \(count) 人", value: $count, in: 5...9)
                    }
                    Picker("自己 · You", selection: $heroSeat) {
                        if editing != nil { Text(noHeroLabel).tag(Optional<Int>.none) }
                        ForEach(visibleSeats, id: \.self) { Text("座位 \($0 + 1) · \(names[$0])").tag(Optional($0)) }
                    }
                    Picker("按钮 · BTN", selection: $buttonSeat) {
                        ForEach(visibleSeats, id: \.self) { Text("座位 \($0 + 1)").tag($0) }
                    }
                } header: { Text(createSession ? "连续场次" : "历史牌局") } footer: {
                    Text(editing == nil ? "以下为可修改的起始配置。手牌与公共牌可在创建后补录；不记得的筹码请选“未知”。" : "此处更正本手起始事实，保存前会预览重新推导结果。已有事件时保留座位与玩家身份；加入、离开及换座属于场次管理。")
                }
                Section {
                    Picker("赛制", selection: $gameFormat) {
                        Text("未注明").tag(Optional<HandGameFormat>.none)
                        ForEach(HandGameFormat.allCases, id: \.self) { format in
                            Text(format.title).tag(Optional(format))
                        }
                    }
                } header: { Text("赛制记录") } footer: {
                    Text("未注明时不会猜测赛制。两种赛制均按常规无限注德扑筹码 EV 分析；锦标赛不包含 ICM 或奖金计算。")
                }
                Section("盲注与前注 · 筹码") {
                    amountRow("小盲 · SB", text: $smallBlind)
                    amountRow("大盲 · BB", text: $bigBlind)
                    Picker("前注 · Ante", selection: $anteType) {
                        Text("无前注").tag("none")
                        Text("每位玩家").tag("each")
                        Text("大盲支付").tag("bb")
                        Text("按钮支付").tag("button")
                    }
                    if anteType != "none" { amountRow("前注金额", text: $anteAmount) }
                }
                Section {
                    ForEach(visibleSeats, id: \.self) { seat in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                HandPortrait(seat: seat, hero: seat == heroSeat)
                                TextField("玩家名称", text: $names[seat]).focused($isEditing)
                                Text(seat == heroSeat ? "YOU" : "\(seat + 1)")
                                    .font(.caption.weight(.semibold)).foregroundStyle(HandStyle.muted)
                                if seat == buttonSeat { Text("BTN").font(.caption.weight(.semibold)) }
                            }
                            Picker("筹码精度", selection: $certainties[seat]) {
                                Text("确定").tag(ValueCertainty.exact)
                                Text("近似").tag(ValueCertainty.approximate)
                                Text("未知").tag(ValueCertainty.unknown)
                            }.pickerStyle(.segmented)
                            if certainties[seat] != .unknown {
                                amountRow(certainties[seat] == .approximate ? "起始筹码 · 近似" : "起始筹码 · 确定", text: $stacks[seat])
                            } else {
                                Text("起始筹码 · 未知").font(.subheadline).foregroundStyle(HandStyle.muted)
                            }
                        }.padding(.vertical, 5)
                    }
                } header: { Text("固定座位 · 起始筹码") }
                Section {
                    amountRow("最小筹码单位", text: $minimumUnit).disabled(hasRecordedEvents)
                } header: { Text("高级设置") } footer: {
                    Text(hasRecordedEvents ? "已有事件的最小筹码单位保持锁定，避免把既有账目重新解释为另一金额。" : "例如 1、0.5、0.1。所有输入须为该单位的整数倍；BB 显示换算不改变账目。")
                }
                Section {
                    Button(action: create) {
                        Text(editing == nil ? "创建并开始录入" : "预览更正结果").frame(maxWidth: .infinity).fontWeight(.semibold)
                    }.listRowBackground(HandStyle.green).foregroundStyle(.white)
                }
            }
            .scrollContentBackground(.hidden).background(HandStyle.canvas)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(editing == nil ? (createSession ? "新建实时场次" : "新建历史牌局") : "更正起始信息").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "创建" : "预览", action: create).fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成输入") { isEditing = false }
                }
            }
            .alert("请检查牌局信息", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("继续修改", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .task {
                guard !loaded else { return }; loaded = true
                if let editing { loadConfiguration(editing); title = editing.title }
            }
            .sheet(item: $correctionPreview) { candidate in
                if let session = store.sessionRequiringCorrection(for: candidate) {
                    let impact = store.previewSessionCorrection(session, request: .hand(replacement: candidate))
                    SessionCorrectionView(preview: impact, store: store) {
                        correctionPreview = nil
                        dismiss()
                        onCreated(candidate.id)
                    }
                } else { correctionSheet(candidate) }
            }
            .onChange(of: count) { _, new in
                if let seat = heroSeat { heroSeat = min(seat, new - 1) }
                buttonSeat = min(buttonSeat, new - 1)
            }
        }.tint(HandStyle.green)
    }

    private func amountRow(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("金额", text: text).focused($isEditing).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .frame(minWidth: 64, maxWidth: 120).accessibilityLabel(label)
        }
    }
    private func parsed(_ text: String, unit: ChipUnit, certainty: ValueCertainty = .exact) -> ChipAmount? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil else { return nil }
        return unit.parse(text, certainty: certainty)
    }
    private func reuseConfiguration() {
        guard let hand = store.hands.max(by: { $0.updatedAt < $1.updatedAt }),
              (5...9).contains(hand.configuration.tableCapacity),
              hand.players.count == hand.configuration.tableCapacity else { return }
        loadConfiguration(hand)
    }
    private func loadConfiguration(_ hand: HandRecord) {
        gameFormat = hand.gameFormat
        count = hand.configuration.tableCapacity
        buttonSeat = hand.configuration.buttonSeat
        heroSeat = hand.players.first(where: { $0.isHero })?.seat
        if editing == nil, heroSeat == nil { heroSeat = hand.players.first?.seat ?? 0 }
        let unit = hand.configuration.chipUnit
        minimumUnit = unit.decimal
        smallBlind = unit.format(units: hand.configuration.smallBlind)
        bigBlind = unit.format(units: hand.configuration.bigBlind)
        switch hand.configuration.ante {
        case .none: anteType = "none"; anteAmount = "0"
        case .perPlayer(let value): anteType = "each"; anteAmount = unit.format(units: value)
        case .bigBlind(let value): anteType = "bb"; anteAmount = unit.format(units: value)
        case .button(let value): anteType = "button"; anteAmount = unit.format(units: value)
        }
        for player in hand.players where (0..<9).contains(player.seat) {
            names[player.seat] = player.name
            certainties[player.seat] = player.startingStack.certainty
            stacks[player.seat] = player.startingStack.units.map { unit.format(units: $0) } ?? ""
        }
        error = nil
    }
    private func create() {
        isEditing = false
        error = nil
        let unitText = minimumUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard unitText.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil else {
            error = "最小筹码单位请输入正数，例如 1 或 0.5。"; return
        }
        let unit = ChipUnit(decimal: unitText)
        guard unit.value != nil,
              let sb = parsed(smallBlind, unit: unit)?.units, sb > 0,
              let bb = parsed(bigBlind, unit: unit)?.units, bb > 0 else {
            error = "请检查盲注：小盲与大盲须分别大于 0，且均为最小筹码单位的整数倍。"; return
        }
        var ante: AnteRule = .none
        if anteType != "none" {
            guard let amount = parsed(anteAmount, unit: unit)?.units, amount > 0 else {
                error = "前注须大于 0，且为最小筹码单位的整数倍。"; return
            }
            switch anteType { case "each": ante = .perPlayer(amount); case "bb": ante = .bigBlind(amount); default: ante = .button(amount) }
        }
        var players: [HandPlayer] = []
        for seat in visibleSeats {
            let name = names[seat].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { error = "请填写座位 \(seat + 1) 的玩家名称。"; return }
            let originalPlayer = editing?.players.first(where: { $0.seat == seat })
            var stack: ChipAmount
            if certainties[seat] == .unknown { stack = .unknown }
            else {
                // Historical corrections can derive a zero starting balance without changing the dealt roster.
                let canRetainZero = originalPlayer?.startingStack.units == 0
                guard let amount = parsed(stacks[seat], unit: unit, certainty: certainties[seat]), let value = amount.units,
                      value > 0 || (value == 0 && canRetainZero) else {
                    let requirement = canRetainZero ? "须大于或等于 0" : "须大于 0"
                    error = "请检查 \(name) 的起始筹码：\(requirement) 且符合最小筹码单位，或明确选择未知。"; return
                }
                stack = amount
            }
            if let originalPlayer, editing?.configuration.chipUnit == unit,
               originalPlayer.startingStack.units == stack.units,
               originalPlayer.startingStack.certainty == stack.certainty {
                // Unchanged inputs keep their inherited or unknown provenance.
                stack = originalPlayer.startingStack
            }
            if var existing = originalPlayer {
                existing.name = name
                existing.startingStack = stack
                existing.isHero = seat == heroSeat
                players.append(existing)
            } else {
                players.append(HandPlayer(name: name, seat: seat, startingStack: stack, isHero: seat == heroSeat))
            }
        }
        let configuration = HandConfiguration(tableCapacity: count, buttonSeat: buttonSeat, smallBlind: sb, bigBlind: bb, ante: ante, chipUnit: unit)
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let handTitle = finalTitle.isEmpty ? (editing?.title ?? "历史牌局 \(store.hands.count + 1)") : finalTitle
        if createSession && editing == nil {
            do {
                var session = try SessionReducer.makeSession(title: finalTitle.isEmpty ? "实时场次 \(store.sessions.count + 1)" : finalTitle, configuration: configuration, players: players, gameFormat: gameFormat)
                let hand = try SessionReducer.startNextHand(&session, hands: store.hands)
                try store.saveSession(session, hand: hand)
                try store.updateSelection(StoreSelection(lastHandID: hand.id, selectedEventID: hand.events.last?.id, lastSessionID: session.id))
                dismiss()
                onCreated(hand.id)
            } catch { self.error = error.localizedDescription }
            return
        }
        var generated = HandReducer.makeHand(configuration: configuration, players: players, title: handTitle)
        generated.gameFormat = gameFormat
        if var corrected = editing {
            corrected = store.preparingFactEdit(corrected)
            guard !hasRecordedEvents || configuration.chipUnit == corrected.configuration.chipUnit else {
                error = "已有事件时不能修改最小筹码单位。"; return
            }
            let moneyChanged = corrected.configuration != configuration || corrected.players.count != players.count || players.contains { player in
                guard let original = corrected.players.first(where: { $0.id == player.id }) else { return true }
                return original.seat != player.seat || original.startingStack.units != player.startingStack.units
                    || original.startingStack.certainty != player.startingStack.certainty
            }
            corrected.title = handTitle
            corrected.gameFormat = gameFormat
            corrected.configuration = configuration
            corrected.players = players
            if moneyChanged {
                // Only regenerate the initial SB/BB/Ante prefix. Every later fact stays untouched.
                let prefix = Array(corrected.events.prefix { [.smallBlind, .bigBlind, .ante].contains($0.kind) && $0.street == .preflop })
                var replacement = generated.events
                for index in replacement.indices {
                    if let original = prefix.first(where: { $0.kind == replacement[index].kind && $0.playerID == replacement[index].playerID }) {
                        replacement[index].id = original.id
                    }
                }
                corrected.events = replacement + Array(corrected.events.dropFirst(prefix.count))
            }
            corrected.touch()
            correctionPreview = corrected
        } else { persist(generated) }
    }
    private func persist(_ hand: HandRecord) {
        do {
            try store.upsert(hand)
            let selected = editing == nil ? hand.events.last?.id : store.selection.selectedEventID
            let retainedSelection = selected.flatMap { id in hand.events.contains(where: { $0.id == id }) ? id : nil }
            try store.updateSelection(StoreSelection(lastHandID: hand.id, selectedEventID: retainedSelection))
            dismiss()
            onCreated(hand.id)
        } catch { self.error = error.localizedDescription }
    }
    private func correctionSheet(_ candidate: HandRecord) -> some View {
        let before = editing.map { HandReducer.project($0) }
        let after = HandReducer.project(candidate)
        let unit = candidate.configuration.chipUnit
        return NavigationStack {
            List {
                Section("赛制记录") {
                    LabeledContent("更正前", value: editing?.gameFormat?.title ?? "未注明")
                    LabeledContent("更正后", value: candidate.gameFormat?.title ?? "未注明")
                }
                Section("底池重新推导") {
                    LabeledContent("更正前", value: editing?.configuration.chipUnit.format(before?.latest.pot ?? .unknown) ?? "未知")
                    LabeledContent("更正后", value: unit.format(after.latest.pot))
                    if before?.latest.blocked == true || after.latest.blocked {
                        Text("存在冲突的结果只表示最后有效节点的底池，后续计算暂停。").font(.footnote).foregroundStyle(HandStyle.red)
                    }
                }
                Section("保留原始记录") {
                    Text("仅按更正的配置与起始筹码重算开局 SB、BB 和 Ante；其余行动与发牌逐条保留，不自动改写金额或删除冲突。")
                    Text("匹配的强制投入节点保留身份，后续节点、玩家身份和底牌保持不变。").font(.footnote).foregroundStyle(HandStyle.muted)
                    if candidate.settlement != nil {
                        Text("已有结算将标为失效，需按更正后的事实重新核对。").foregroundStyle(HandStyle.red)
                    }
                }
                Section("核对结果 · \(after.issues.count) 项") {
                    if after.issues.isEmpty {
                        Label("未发现行动规则冲突", systemImage: "checkmark.circle").foregroundStyle(HandStyle.green)
                    } else {
                        ForEach(after.issues) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                if let id = issue.eventID, let index = candidate.events.firstIndex(where: { $0.id == id }) {
                                    Text("事件 #\(index + 1)").font(.caption).foregroundStyle(HandStyle.muted)
                                }
                                Text(issue.message).foregroundStyle(HandStyle.red)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(HandStyle.canvas)
            .navigationTitle("确认起始更正").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("返回修改") { correctionPreview = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(after.issues.isEmpty ? "保存" : "保留冲突并保存") {
                        correctionPreview = nil
                        persist(candidate)
                    }
                }
            }
        }.tint(HandStyle.green)
    }

}
