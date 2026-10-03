import SwiftUI

struct CardEntryScreen: View {
    let title: String
    let count: Int
    let initial: [PokerCard]
    let used: Set<PokerCard>
    let finish: ([PokerCard]?) -> Void
    @State private var selected: [PokerCard] = []
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { finish(nil) } label: {
                        Text("取消选牌").frame(minWidth: 72, minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("取消选牌")
                    Spacer(minLength: 0)
                    Text(title).font(.headline).multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                    Button { finish(selected) } label: {
                        Text("确认选牌").fontWeight(.semibold).frame(minWidth: 72, minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("确认选牌")
                    .disabled(selected.count != count)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(HandStyle.canvas)
                Divider()
                ScrollView {
                VStack(spacing: 22) {
                    HStack(spacing: 10) {
                        ForEach(0..<count, id: \.self) { index in
                            if selected.indices.contains(index) {
                                Button { selected.remove(at: index) } label: { PlayingCard(value: selected[index].display) }
                            } else {
                                RoundedRectangle(cornerRadius: 6).stroke(HandStyle.line, style: StrokeStyle(lineWidth: 2, dash: [3]))
                                    .frame(width: 35, height: 46).overlay(Text("＋").foregroundStyle(HandStyle.muted))
                            }
                        }
                    }.padding(.top, 20)
                    Text("已选 \(selected.count)/\(count) · 点击已选牌可释放").font(.caption).foregroundStyle(HandStyle.muted)
                    ForEach(CardSuit.allCases, id: \.self) { suit in
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 9) {
                            ForEach((2...14).reversed(), id: \.self) { rank in
                                let card = PokerCard(rank: rank, suit: suit)
                                let occupied = used.contains(card) && !initial.contains(card)
                                Button {
                                    if let i = selected.firstIndex(of: card) { selected.remove(at: i) }
                                    else if selected.count < count { selected.append(card) }
                                } label: { PlayingCard(value: card.display).opacity(occupied ? 0.18 : 1).overlay(RoundedRectangle(cornerRadius: 6).stroke(selected.contains(card) ? HandStyle.green : .clear, lineWidth: 3)) }
                                    .disabled(occupied || (selected.count >= count && !selected.contains(card)))
                            }
                        }
                    }
                }.padding(18)
                }.background(HandStyle.canvas)
            }
            .background(HandStyle.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }.onAppear { selected = initial }
    }
}

struct ActionEntryScreen: View {
    let hand: HandRecord
    let editing: HandEvent?
    var insertionIndex: Int? = nil
    var allowIncomplete = false
    let finish: (HandEvent?) -> Void
    @State private var kind: HandEventKind = .fold
    @State private var input = ""
    @State private var useBB = false
    @State private var certainty: ValueCertainty = .exact
    @State private var source = "手动录入"
    @State private var amountSource = "手动录入"
    @State private var selectedStreet: HandStreet = .preflop
    @State private var selectedPlayerID: UUID?
    @State private var showReview = false
    @State private var error: String?
    @FocusState private var amountFocused: Bool

    private var historical: Bool { editing != nil || insertionIndex != nil || allowIncomplete }
    private var index: Int {
        editing.flatMap { event in hand.events.firstIndex { $0.id == event.id } }
            ?? insertionIndex.map { min(max(0, $0), hand.events.count) } ?? hand.events.count
    }
    private var prefixHand: HandRecord {
        var prefix = hand; prefix.events = Array(hand.events.prefix(index)); return prefix
    }
    private var snapshot: HandSnapshot { HandReducer.project(prefixHand).latest }
    private var legal: LegalActions { HandReducer.legalActions(in: snapshot, hand: prefixHand) }
    private var supplemental: Bool { kind == .liveBlind || kind == .deadBlind }
    private var actor: HandPlayer? { hand.players.first { $0.id == (historical || supplemental ? selectedPlayerID : legal.actorID) } }
    private var money: Bool { [.call, .bet, .raiseTo, .allIn, .smallBlind, .bigBlind, .ante, .deadBlind, .liveBlind].contains(kind) }
    private var automaticAmount: Bool { !historical && (kind == .call || kind == .allIn) }
    private var available: [HandEventKind] {
        if historical {
            var actions: [HandEventKind] = [.fold, .check, .call, .bet, .raiseTo, .allIn, .liveBlind, .deadBlind]
            if let editing, !actions.contains(editing.kind) { actions.append(editing.kind) }
            return actions
        }
        var result: [HandEventKind] = []
        if legal.canFold { result.append(.fold) }
        if legal.canCheck { result.append(.check) }
        if legal.canCall { result.append(.call) }
        if legal.canRaise { result.append(snapshot.currentBet == 0 ? .bet : .raiseTo) }
        if legal.canAllIn { result.append(.allIn) }
        if snapshot.street == .preflop && snapshot.forcedContributionsComplete && !snapshot.blocked && !snapshot.roundComplete && !snapshot.handComplete {
            result += [.liveBlind, .deadBlind]
        }
        return result
    }
    private func parseInput(_ text: String, bb: Bool) -> ChipAmount? {
        if !bb { return hand.configuration.chipUnit.parse(text, certainty: certainty) }
        guard text.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value >= 0 else { return nil }
        var units = value * Decimal(hand.configuration.bigBlind)
        var integer = Decimal()
        NSDecimalRound(&integer, &units, 0, .plain)
        guard integer == units, units <= Decimal(Int64.max) else { return nil }
        return .init(units: NSDecimalNumber(decimal: units).int64Value, certainty: certainty)
    }
    private var enteredAmount: ChipAmount? {
        guard money else { return nil }
        if certainty == .unknown { return .init(units: nil, source: amountSource) }
        let amount: ChipAmount?
        if automaticAmount {
            amount = (kind == .call ? Optional(legal.callTo) : legal.maximumTo).map { .init(units: $0, certainty: certainty) }
        } else { amount = parseInput(input, bb: useBB) }
        guard var amount else { return nil }
        amount.source = amountSource
        return amount
    }
    private var draft: HandEvent {
        HandEvent(id: editing?.id ?? UUID(), street: historical ? selectedStreet : snapshot.street,
                  playerID: actor?.id, kind: kind, amount: enteredAmount, source: source)
    }
    private var inputProblem: String? {
        if actor == nil { return "请选择行动玩家" }
        if money && enteredAmount == nil { return "金额须为最小单位 \(hand.configuration.chipUnit.decimal) 的整数倍；不会自动取整" }
        return nil
    }
    private var problems: [String] { HandReducer.validate(draft, in: prefixHand) }
    private var affectedIssues: [String] {
        guard historical else { return [] }
        var candidate = hand
        let event = draft
        if editing != nil, candidate.events.indices.contains(index) { candidate.events[index] = event }
        else { candidate.events.insert(event, at: index) }
        let affectedIDs = Set(candidate.events.dropFirst(index + 1).map(\.id))
        return HandReducer.project(candidate).issues.filter { issue in
            issue.eventID.map { affectedIDs.contains($0) } ?? false
        }.map(\.message).reduce(into: [String]()) { result, message in
            if !result.contains(message) { result.append(message) }
        }
    }
    private var canSave: Bool { inputProblem == nil && (historical || (problems.isEmpty && !snapshot.blocked && available.contains(kind))) }
    private func changeUnit(_ bb: Bool) {
        showReview = false
        error = nil
        if automaticAmount || input.isEmpty { useBB = bb; return }
        guard let units = parseInput(input, bb: useBB)?.units else {
            error = "请先修正金额，再切换单位；原输入已保留"; return
        }
        let converted: String
        if bb {
            guard hand.configuration.bigBlind > 0 else { return }
            converted = NSDecimalNumber(decimal: Decimal(units) / Decimal(hand.configuration.bigBlind)).stringValue
        } else { converted = hand.configuration.chipUnit.format(units: units) }
        guard parseInput(converted, bb: bb)?.units == units else {
            error = "此金额无法无损换算为当前显示单位，请保留原单位"; return
        }
        input = converted; useBB = bb
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 12) {
                        if let actor { HandPortrait(seat: actor.seat, hero: actor.isHero, size: 48) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(actor?.name ?? "暂无行动者").font(.title2.weight(.semibold))
                            Text("\((historical ? selectedStreet : snapshot.street).label) · \(historical ? "按记忆核对记录" : "继续最新进度")").font(.caption).foregroundStyle(HandStyle.muted)
                        }
                    }
                    if historical {
                        VStack(alignment: .leading, spacing: 10) {
                            if insertionIndex != nil { Text("插入位置：已有第 \(index) 条记录之后").font(.subheadline.weight(.semibold)) }
                            Picker("街次", selection: $selectedStreet) {
                                ForEach(HandStreet.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            Picker("玩家", selection: $selectedPlayerID) {
                                ForEach(hand.players) { Text($0.name).tag(Optional($0.id)) }
                            }
                            Text("只记录已知事实；缺少的行动不会自动补齐。冲突可保存为待修正草稿，解决后才能继续正常录入。").font(.caption).foregroundStyle(HandStyle.muted)
                        }.handPanel()
                    }
                    if supplemental && !historical {
                        Picker("实际补盲玩家", selection: $selectedPlayerID) {
                            ForEach(hand.players) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Text(kind == .liveBlind ? "本次支付计入本街投入，减少之后待跟注；不会抬高下注级别。" : "本次支付只计入底池，不抵扣之后待跟注。")
                            .font(.caption).foregroundStyle(HandStyle.muted)
                    }
                    HStack {
                        stat("Pot", snapshot.pot)
                        Spacer()
                        stat("后手", actor.flatMap { snapshot.player($0.id)?.remaining } ?? .unknown)
                        Spacer()
                        stat("本街已投", actor.flatMap { snapshot.player($0.id)?.streetContribution } ?? .unknown)
                    }.handPanel()
                    if historical && selectedStreet != snapshot.street {
                        Text("以上数值为插入位置之前的已知状态；缺少跨街过程时，本次投入待核对。").font(.caption).foregroundStyle(HandStyle.muted)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(available, id: \.self) { action in
                            Button { kind = action } label: {
                                Text(action.label).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 15)
                                    .background(kind == action ? HandStyle.color(action).opacity(0.15) : .white, in: RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(kind == action ? HandStyle.color(action) : .clear, lineWidth: 2))
                            }
                        }
                    }
                    if money {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(kind.isForced ? "本次强制投入" : "\(kind.title) · 本街总额").font(.headline)
                                Spacer()
                                Toggle("BB", isOn: Binding(get: { useBB }, set: { newValue in changeUnit(newValue) })).fixedSize()
                            }
                            Picker("金额精度", selection: $certainty) {
                                Text("精确").tag(ValueCertainty.exact)
                                Text("近似").tag(ValueCertainty.approximate)
                                if historical { Text("未知").tag(ValueCertainty.unknown) }
                            }.pickerStyle(.segmented)
                            if certainty == .unknown {
                                Text("未知").font(.system(size: 42, weight: .medium, design: .rounded))
                                Text("未知金额保留为草稿；依赖此金额的底池、筹码和后续行动需先核对。").font(.caption).foregroundStyle(HandStyle.muted)
                            } else if automaticAmount {
                                Text(enteredAmount.map { amount in
                                    if useBB, let units = amount.units, hand.configuration.bigBlind > 0 {
                                        return (certainty == .approximate ? "≈" : "") + NSDecimalNumber(decimal: Decimal(units) / Decimal(hand.configuration.bigBlind)).stringValue + " BB"
                                    }
                                    return hand.configuration.chipUnit.format(amount)
                                } ?? "未知").font(.system(size: 42, weight: .medium, design: .rounded))
                            } else {
                                TextField("输入金额", text: $input).keyboardType(.decimalPad).font(.system(size: 42, weight: .medium, design: .rounded)).focused($amountFocused)
                                if !historical && !supplemental {
                                    HStack {
                                        Button("Min \(hand.configuration.chipUnit.format(units: legal.minimumRaiseTo))") { useBB = false; input = hand.configuration.chipUnit.format(units: legal.minimumRaiseTo) }
                                        Spacer()
                                        if legal.maximumTo != nil { Button("All-in") { kind = .allIn } }
                                    }.font(.caption.weight(.semibold))
                                }
                            }
                            Text(investmentText).font(.subheadline).foregroundStyle(HandStyle.muted)
                            TextField("金额来源", text: $amountSource).font(.subheadline)
                        }.handPanel()
                    }
                    if historical { TextField("记录来源", text: $source).textFieldStyle(.roundedBorder) }
                    if let error { Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(HandStyle.red) }
                    if let inputProblem { Label(inputProblem, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(HandStyle.red) }
                    ForEach(problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(HandStyle.red)
                    }
                    if showReview {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("确认记录").font(.headline)
                            Text("\(draft.street.label) · \(actor?.name ?? "") · \(kind.title) \(enteredAmount.map { hand.configuration.chipUnit.format($0) } ?? "")")
                            if money { Text("金额来源：\(amountSource)").font(.caption).foregroundStyle(HandStyle.muted) }
                            if historical {
                                Text("后续行动保留；冲突会标记待修正。缺项不会视作合法的完整路径。").font(.caption).foregroundStyle(HandStyle.muted)
                                ForEach(affectedIssues, id: \.self) { message in
                                    Text("后续待修正：\(message)").font(.caption).foregroundStyle(HandStyle.red)
                                }
                            }
                        }.handPanel()
                    }
                    Button {
                        amountFocused = false
                        if showReview { finish(draft) } else { showReview = true }
                    } label: { Text(showReview ? (historical && !problems.isEmpty ? "确认并保存待修正草稿" : "确认并保存") : "核对行动").font(.headline).frame(maxWidth: .infinity).padding(17).background(HandStyle.ink, in: Capsule()).foregroundStyle(.white) }
                        .disabled(!canSave)
                }.padding(20)
            }.background(HandStyle.canvas).navigationTitle(editing != nil ? "修改行动" : historical ? "补录已知行动" : "记录行动").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { finish(nil) } }; ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { amountFocused = false } } }
        }.onAppear {
            selectedStreet = editing?.street ?? snapshot.street
            selectedPlayerID = editing?.playerID ?? legal.actorID ?? hand.players.first?.id
            kind = editing?.kind ?? available.first ?? .fold
            source = editing?.source ?? (historical ? "记忆补录" : "手动录入")
            amountSource = editing?.amount?.source ?? source
            certainty = editing?.amount?.certainty ?? .exact
            if let units = editing?.amount?.units { input = hand.configuration.chipUnit.format(units: units) }
        }
        .onChange(of: kind) { _, _ in showReview = false }
        .onChange(of: input) { _, _ in showReview = false; error = nil }
        .onChange(of: useBB) { _, _ in showReview = false }
        .onChange(of: certainty) { _, _ in showReview = false }
        .onChange(of: source) { _, _ in showReview = false }
        .onChange(of: amountSource) { _, _ in showReview = false }
        .onChange(of: selectedStreet) { _, _ in showReview = false }
        .onChange(of: selectedPlayerID) { _, _ in showReview = false }
    }
    private var investmentText: String {
        guard let amount = enteredAmount, let units = amount.units else { return "本次投入 未知" }
        if kind.isForced { return "本次投入 \(hand.configuration.chipUnit.format(amount))" }
        guard (!historical || selectedStreet == snapshot.street), !snapshot.blocked,
              let prior = actor.flatMap({ snapshot.player($0.id)?.streetContribution.units }), units >= prior else { return "本次投入 待核对" }
        return "本次投入 \(hand.configuration.chipUnit.format(.init(units: units - prior, certainty: amount.certainty)))"
    }
    private func stat(_ title: String, _ value: ChipAmount) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(HandStyle.muted); Text(hand.configuration.chipUnit.format(value)).font(.title3.weight(.semibold)) }
    }
}
