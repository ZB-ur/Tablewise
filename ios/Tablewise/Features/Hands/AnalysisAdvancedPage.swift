import SwiftUI

struct AnalysisAdvancedPage: View {
    let hand: HandRecord
    let snapshot: HandSnapshot
    let subjectID: UUID
    let reveal: Bool
    let after: Bool
    let eventID: UUID?
    var focusesOuts = false
    var contextLabel: String? = nil

    @State private var outs: OutsReport?
    @State private var outsToken = ""
    @State private var outsMessage: String?
    @State private var outsRunning = false
    @State private var outsWorker: Task<OutsReport, Error>?
    @State private var outsRetry = 0
    @State private var candidates = ["", ""]
    @State private var purposes = Set<AnalysisBetPurpose>()
    @State private var continueAssumption = ""
    @State private var foldAssumption = ""
    @State private var continuingResponse = "未知"

    private var context: AnalysisNodeContext { .init(hand: hand, snapshot: snapshot, subjectID: subjectID, eventID: eventID, after: after) }
    private var subject: HandPlayer? { hand.players.first { $0.id == subjectID } }
    private var outsContext: HandOutsContext { .init(hand: hand, snapshot: snapshot, subjectID: subjectID, reveal: reveal, after: after, eventID: eventID) }
    private var contextToken: String { outsContext.fingerprint }
    private var token: String { contextToken + ":\(outsRetry)" }
    private var currentOuts: OutsReport? { outsToken == token ? outs : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(contextLabel ?? "\(subject?.name ?? "玩家") · \(snapshot.displayStreet.title) · 行动\(after ? "后" : "前")").font(.headline)
                    Text(reveal ? "揭牌视角 · 仅当前公共牌" : "决策视角 · 不使用对手事后手牌").font(.caption).foregroundStyle(HandStyle.muted)
                    HStack(spacing: 5) { ForEach(snapshot.board) { PlayingCard(value: $0.display, small: true) } }
                    if let remembered = hand.rememberedPot(nodeEventID: eventID, after: after) {
                        Text("记忆底池 \(context.amount(remembered.amount)) · 推导底池 \(context.amount(snapshot.pot))")
                            .font(.caption).foregroundStyle(context.potMismatch ? HandStyle.gold : HandStyle.muted)
                    }
                }.handPanel()
                if !focusesOuts {
                    factorPanel
                    stacksPanel
                }
                outsPanel
                if !focusesOuts {
                    scenariosPanel
                    purposesPanel
                }
            }.padding(16)
        }
        .background(HandStyle.canvas).foregroundStyle(HandStyle.ink)
        .navigationTitle(focusesOuts ? "改善牌详情" : "进阶分析").navigationBarTitleDisplayMode(.inline)
        .task(id: token) { await calculateOuts() }
        .onDisappear { outsWorker?.cancel() }
        .onChange(of: contextToken) { _, _ in
            candidates = ["", ""]; purposes = []; continueAssumption = ""; foldAssumption = ""; continuingResponse = "未知"
        }
    }

    private var factorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("当前关键因素", systemImage: "lightbulb").font(.headline)
            let factors = AnalysisFactorGuide.factors(hand: hand, snapshot: snapshot, subjectID: subjectID, eventID: eventID, after: after)
            Text(factors[0].title).font(.subheadline.weight(.semibold))
            DisclosureGroup("依据与其他因素") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(factors) { factor in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(factor.title).font(.subheadline.weight(.medium))
                            Text(factor.detail).font(.caption).foregroundStyle(HandStyle.muted)
                        }
                    }
                }.padding(.top, 8)
            }.font(.caption)
        }.handPanel()
    }

    private var stacksPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("有效筹码与 SPR").font(.headline)
            Text("参考时点：所选节点行动\(after ? "后" : "前")。每一行分别比较一位对手。")
                .font(.caption).foregroundStyle(HandStyle.muted)
            if let player = context.own, !player.folded {
                ForEach(context.opponents) { opponent in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("对 \(context.name(opponent.id))").font(.subheadline.weight(.semibold))
                        Text("剩余：\(context.amount(player.remaining)) / \(context.amount(opponent.remaining)) · 本街已投入：\(context.amount(player.streetContribution)) / \(context.amount(opponent.streetContribution))")
                            .font(.caption).foregroundStyle(HandStyle.muted)
                        if snapshot.blocked || snapshot.hasUncertainty || context.potMismatch {
                            Text("记录有冲突、金额不确定或记忆底池有差异，SPR 待核对").font(.caption).foregroundStyle(HandStyle.gold)
                        } else if context.hasUnmatchedStreet {
                            Text("存在未匹配的本街投入，暂不将下注后的余额直接代入 SPR。")
                                .font(.caption).foregroundStyle(HandStyle.gold)
                        } else if context.potStructure == nil {
                            Text("底池层级待核对，暂不输出 SPR").font(.caption).foregroundStyle(HandStyle.gold)
                        } else if let a = player.remaining.units, let b = opponent.remaining.units {
                            let effective = Double(min(a, b))
                            let pot = context.commonPot(with: opponent.id)
                            if let ratio = PokerMath.spr(effectiveStackAtSameInstant: effective, potAtSameInstant: pot) {
                                HStack { stat("有效后手", context.amountUnits(effective)); Spacer(); stat("共同可争夺池", context.amountUnits(pot)); Spacer(); stat("SPR", String(format: "%.2f", ratio)) }
                            } else { Text("当前共同可争夺池为零，SPR 不适用").font(.caption).foregroundStyle(HandStyle.muted) }
                        }
                    }
                    if opponent.id != context.opponents.last?.id { Divider() }
                }
                if context.opponents.isEmpty { Text("当前没有未弃牌对手").font(.subheadline).foregroundStyle(HandStyle.muted) }
            } else { Text("分析对象已弃牌或不在当前节点").font(.subheadline).foregroundStyle(HandStyle.muted) }
            DisclosureGroup("公式与口径") {
                Text("有效后手 = 双方当前剩余筹码较小值；SPR = 有效后手 ÷ 双方均有资格争夺的已投入底池。共同底池按投入层级包含弃牌死钱、排除双方无资格的边池和未匹配顶层。不混用下注前底池与下注后余额；存在本街未匹配投入时暂停此简化比值。")
                    .font(.caption).foregroundStyle(HandStyle.muted).padding(.top, 6)
            }.font(.caption)
        }.handPanel()
    }

    private var outsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("改善牌与危险牌").font(.headline)
            Text("均匀未知牌模型 · 排除当前视角已知牌；未使用对手范围的加权分布。")
                .font(.caption).foregroundStyle(HandStyle.muted)
            if let unavailable = outsContext.unavailableMessage {
                Text(unavailable).font(.subheadline).foregroundStyle(HandStyle.muted)
            } else if let report = currentOuts {
                if report.cardsToCome == 0 {
                    Text("河牌无后续公共牌，Outs 不适用。").font(.subheadline)
                } else {
                    Text("当前 \(report.currentCategory.title) · \(report.unseenCount) 张未知牌 · 还发 \(report.cardsToCome) 张")
                        .font(.caption).foregroundStyle(HandStyle.muted)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("至少一项成牌目标 · 重叠已去重").font(.subheadline.weight(.semibold))
                        HStack {
                            stat("下一张 · \(report.combinedNextCards.count)/\(report.unseenCount) 张", probability(Double(report.combinedNextCards.count) / Double(report.unseenCount)))
                            Spacer()
                            stat("截至河牌", probability(report.combinedByRiverProbability))
                        }
                        DisclosureGroup("合并后的具体牌张") {
                            Text(report.combinedNextCards.isEmpty ? "无单张牌达成上述成牌目标" : report.combinedNextCards.map(cardLabel).joined(separator: "  "))
                                .font(.caption.monospaced()).padding(.top, 4)
                        }.font(.caption)
                    }
                    ForEach(report.events) { event in eventRow(event, report: report) }
                    Text("精确枚举 \(report.runoutCount) 种余下公共牌 · \(String(format: "%.2f", report.elapsedSeconds)) 秒")
                        .font(.caption2).foregroundStyle(HandStyle.muted)
                    Text("成牌改善概率不是权益或必胜概率。目标之间可能重叠，不能相加成总 Outs。每项目标的牌张已去重；公共牌本身形成的改善也计入，不代表自己的相对牌力一定更强。")
                        .font(.caption).foregroundStyle(HandStyle.muted)
                    if !report.comparesKnownOpponents {
                        Text("反超与被反超概率待明确对手条件。本页仅在揭牌视角、所有未弃牌对手底牌完整时计算比较；范围条件比较可返回节点详情，打开「范围条件下的反超与危险牌」。")
                            .font(.caption).foregroundStyle(HandStyle.gold)
                    } else {
                        Text("领先比较针对所有已知未弃牌对手的当前最佳五张，不包含底池资格或未来下注。转河之间可能先领先再落后，河牌概率只表示最终牌力关系。")
                            .font(.caption).foregroundStyle(HandStyle.muted)
                    }
                }
            } else if outsToken == token && outsRunning {
                HStack { ProgressView(); Text("正在枚举改善牌…").font(.subheadline); Spacer(); Button("取消") { outsWorker?.cancel() } }
            } else {
                Text(outsToken == token ? outsMessage ?? "待计算" : "输入已变化，旧结果已失效")
                    .font(.subheadline).foregroundStyle(HandStyle.muted)
                Button("重试") { outsRetry += 1 }.font(.caption)
            }
        }.handPanel()
    }

    @ViewBuilder private func eventRow(_ event: ImprovementEvent, report: OutsReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            Text(event.target.title).font(.subheadline.weight(.semibold))
            if event.alreadyAchieved {
                Text("当前已经具备，不计为待改善目标").font(.caption).foregroundStyle(HandStyle.muted)
            } else {
                HStack {
                    stat("下一张 · \(event.nextCards.count)/\(report.unseenCount) 张", probability(event.nextProbability))
                    Spacer()
                    stat(event.target == .takeLead || event.target == .loseShare ? "河牌时" : "截至河牌", probability(event.byRiverProbability))
                }
                DisclosureGroup("具体牌张") {
                    Text(event.nextCards.isEmpty ? "没有单张可达成此目标的牌（真实 0 张）" : event.nextCards.map(cardLabel).joined(separator: "  "))
                        .font(.caption.monospaced()).padding(.top, 5)
                }.font(.caption)
                if report.cardsToCome == 2 {
                    DisclosureGroup("仅两张配合 · \(event.backdoorPaths.count) 条路径 · \(probability(event.backdoorProbability))") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("以下每对牌单独来任一张均不能达成目标，必须两张同时出现；两种先后顺序均计入。它们不计入上面的单张 Outs。")
                                .font(.caption).foregroundStyle(HandStyle.muted)
                            if event.backdoorPaths.isEmpty { Text("无此类后门路径").font(.caption) }
                            else {
                                NavigationLink("查看全部两张路径") {
                                    AnalysisRunoutList(title: event.target.title, paths: event.backdoorPaths)
                                }.font(.subheadline)
                            }
                        }.padding(.top, 5)
                    }.font(.caption)
                }
            }
        }
    }

    private var scenariosPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("被跟注后的后果").font(.headline)
            if let reason = context.scenarioRestriction {
                Text(reason).font(.subheadline).foregroundStyle(HandStyle.muted)
                Text("当前只计算双人、翻后首次下注、双方可覆盖下注的情景；加注、多人和不同池资格暂不套此公式。")
                    .font(.caption).foregroundStyle(HandStyle.muted)
            } else {
                Text("输入两个候选下注额，假设对手恰好跟注。不预测对手是否会跟注或弃牌。")
                    .font(.caption).foregroundStyle(HandStyle.muted)
                ForEach(candidates.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(index == 0 ? "方案 A" : "方案 B").font(.subheadline.weight(.semibold))
                            TextField("下注筹码", text: $candidates[index]).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                                .accessibilityLabel("\(index == 0 ? "方案 A" : "方案 B")下注金额")
                            if let pot = snapshot.pot.units, pot % 2 == 0 {
                                Button("½ 池") { candidates[index] = hand.configuration.chipUnit.format(units: pot / 2) }.font(.caption)
                            }
                            Button("满池") { if let pot = snapshot.pot.units { candidates[index] = hand.configuration.chipUnit.format(units: pot) } }.font(.caption)
                        }
                        if let scenario = context.scenario(candidates[index]) {
                            HStack { stat("跟后底池", context.amountUnits(scenario.result.potAfterCall)); Spacer(); stat("我方后手", context.amountUnits(scenario.result.bettorRemaining)); Spacer(); stat("对方后手", context.amountUnits(scenario.result.callerRemaining)) }
                            HStack { stat("跟后 SPR", String(format: "%.2f", scenario.result.spr)); Spacer(); stat("对手跟注价格", probability(scenario.result.opponentCallPrice)) }
                            DisclosureGroup("公式与 MDF / Alpha") {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("跟后池 = 当前池 + 2 × 下注；双方后手各减下注；跟后 SPR = 较小后手 ÷ 跟后池；对手价格 = 下注 ÷ 跟后池。")
                                    if let bounds = PokerMath.alphaMDF(pot: Double(snapshot.pot.units ?? 0), bet: Double(scenario.bet), headsUpFirstBet: true) {
                                        Text("Alpha = B ÷ (P + B) = \(probability(bounds.alpha))")
                                        Text("MDF = P ÷ (P + B) = \(probability(bounds.mdf))")
                                    }
                                    Text("双人简化首次下注模型：P 为下注前池，B 为下注；以零摊牌价值诈唬且无后续收益为基准。Alpha 是该模型的盈亏平衡弃牌频率；MDF 是互补防守比例，不是必须防守的频率，也不适用于当前未建模的加注或多人决策。")
                                }.font(.caption).foregroundStyle(HandStyle.muted).padding(.top, 6)
                            }.font(.caption)
                        } else {
                            Text(candidates[index].isEmpty ? "输入金额后查看真实节点下的结果" : "金额需符合最小筹码单位、合法首次下注下限，且不超过双方可用筹码。")
                                .font(.caption).foregroundStyle(HandStyle.muted)
                        }
                    }.padding(12).background(HandStyle.canvas, in: RoundedRectangle(cornerRadius: 14))
                }
                Text("情景只预览被跟后的后果，不写入原始牌局，不生成此下注的精确 EV。").font(.caption).foregroundStyle(HandStyle.muted)
            }
        }.handPanel()
    }

    private var purposesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("下注目的检查").font(.headline)
            Text("可同时选择多个目的，并写出自己的对手反应假设。").font(.caption).foregroundStyle(HandStyle.muted)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(AnalysisBetPurpose.allCases) { purpose in
                    Button {
                        if purposes.contains(purpose) { purposes.remove(purpose) } else { purposes.insert(purpose) }
                    } label: {
                        HStack { Image(systemName: purposes.contains(purpose) ? "checkmark.circle.fill" : "circle"); Text(purpose.rawValue); Spacer() }
                            .font(.subheadline).padding(10).background(purposes.contains(purpose) ? HandStyle.green.opacity(0.12) : HandStyle.canvas, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityAddTraits(purposes.contains(purpose) ? .isSelected : [])
                }
            }
            TextField("哪些较弱／较强组合会继续？", text: $continueAssumption, axis: .vertical)
                .textFieldStyle(.roundedBorder).accessibilityLabel("对手继续假设")
            TextField("哪些组合会弃牌？", text: $foldAssumption, axis: .vertical)
                .textFieldStyle(.roundedBorder).accessibilityLabel("对手弃牌假设")
            Picker("继续方式", selection: $continuingResponse) {
                Text("未知").tag("未知"); Text("只跟注").tag("只跟注"); Text("可能加注").tag("可能加注")
            }.pickerStyle(.segmented)
            if purposes.isEmpty { Text("先选择希望检查的下注目的").font(.caption).foregroundStyle(HandStyle.muted) }
            ForEach(AnalysisBetPurpose.allCases.filter(purposes.contains)) { purpose in
                VStack(alignment: .leading, spacing: 4) {
                    Text(purpose.rawValue).font(.subheadline.weight(.semibold))
                    Text(purpose.explanation(continues: continueAssumption, folds: foldAssumption, response: continuingResponse))
                        .font(.caption).foregroundStyle(HandStyle.muted)
                }
            }
            Text("这些是本页临时教学假设，不自动转为组合范围或分支概率，也不据此给所有行动计算 EV。")
                .font(.caption).foregroundStyle(HandStyle.muted)
        }.handPanel()
    }

    private func calculateOuts() async {
        let current = token
        outsWorker?.cancel(); outsToken = current; outs = nil; outsMessage = nil; outsRunning = false
        guard outsContext.unavailableMessage == nil else { outsMessage = outsContext.unavailableMessage; return }
        let input = outsContext.inputs()
        let task = Task.detached(priority: .userInitiated) { try PokerOuts.analyze(hole: input.hole, board: input.board, deadCards: input.dead, knownOpponents: input.opponents) }
        outsWorker = task; outsRunning = true
        do {
            let report = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, outsToken == current, token == current else { return }
            outs = report; outsRunning = false; outsWorker = nil
        } catch {
            guard !Task.isCancelled, outsToken == current, token == current else { return }
            outsMessage = error is CancellationError ? "计算已取消" : error.localizedDescription
            outsRunning = false; outsWorker = nil
        }
    }
    private func cardLabel(_ value: Int) -> String { RangePlan.rankLabel(value / 4 + 2) + CardSuit.allCases[value % 4].symbol }
    private func probability(_ value: Double) -> String { String(format: "%.2f%%", value * 100) }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption2).foregroundStyle(HandStyle.muted); Text(value).font(.subheadline.monospacedDigit().weight(.semibold)) }
    }
}

private struct AnalysisRunoutList: View {
    let title: String
    let paths: [ImprovementRunout]
    var body: some View {
        List(paths) { path in
            HStack { PlayingCard(value: label(path.first), small: true); PlayingCard(value: label(path.second), small: true); Spacer(); Text("两种先后均可").font(.caption).foregroundStyle(HandStyle.muted) }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
    private func label(_ value: Int) -> String { RangePlan.rankLabel(value / 4 + 2) + CardSuit.allCases[value % 4].symbol }
}

private enum AnalysisBetPurpose: String, CaseIterable, Identifiable {
    case value = "价值", bluff = "诈唬", semiBluff = "半诈唬", protection = "拒绝权益"
    var id: String { rawValue }
    func explanation(continues: String, folds: String, response: String) -> String {
        let c = continues.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = folds.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, !f.isEmpty else { return "请先写出继续与弃牌两部分假设；缺少对手反应条件，不能判断这一目的是否成立。" }
        let continuation = response == "可能加注" ? "你还假设可能被加注，需另考虑加注分支。" : response == "未知" ? "继续方式未知，不能假定只会被跟注。" : "你假设继续部分只跟注。"
        switch self {
        case .value: return "你预计「\(c)」继续。核对其中哪些比自己的牌更弱、哪些更强；只有愿意支付的较弱部分才能支持价值目的。\(continuation)"
        case .bluff: return "你预计「\(f)」弃牌。核对这些是否包含当前领先于自己的牌；没有明确弃牌概率与后续收益时，不能推导诈唬 EV。\(continuation)"
        case .semiBluff: return "你预计「\(f)」弃牌、「\(c)」继续。若被跟后仍有改善路径，可检查半诈唬目的；上面的成牌改善概率不能直接当作被跟后的获胜概率。\(continuation)"
        case .protection: return "你预计「\(f)」弃牌。检查其中哪些牌虽落后却仍有改善权益；让其弃牌可能拒绝权益，但需同时比较「\(c)」继续时的代价。\(continuation)"
        }
    }
}

private struct AnalysisNodeContext {
    let hand: HandRecord
    let snapshot: HandSnapshot
    let subjectID: UUID
    var eventID: UUID? = nil
    var after: Bool = false
    var potMismatch: Bool { hand.potNeedsReconciliation(nodeEventID: eventID, after: after) }
    var potStructure: AnalysisPotStructure? { try? AnalysisNodePots.build(hand: hand, snapshot: snapshot, eventID: eventID, after: after) }
    var own: PlayerSnapshot? { snapshot.player(subjectID) }
    var active: [PlayerSnapshot] { snapshot.players.filter { !$0.folded } }
    var opponents: [PlayerSnapshot] { active.filter { $0.id != subjectID } }
    var hasUnmatchedStreet: Bool {
        let amounts = active.compactMap(\.streetContribution.units)
        return amounts.count != active.count || Set(amounts).count > 1
    }
    func name(_ id: UUID) -> String { hand.players.first { $0.id == id }?.name ?? "玩家" }
    func amount(_ value: ChipAmount) -> String { hand.configuration.chipUnit.format(value) }
    func amountUnits(_ units: Double) -> String {
        guard units.isFinite, let unit = hand.configuration.chipUnit.value else { return "未知" }
        return NSDecimalNumber(decimal: Decimal(units) * unit).stringValue
    }
    func commonPot(with opponent: UUID) -> Double {
        guard let structure = potStructure else { return 0 }
        return structure.layers.filter { $0.eligibleIDs.contains(subjectID) && $0.eligibleIDs.contains(opponent) }
            .reduce(0.0) { $0 + Double($1.units) }
    }
    var scenarioRestriction: String? {
        guard !snapshot.blocked, !snapshot.hasUncertainty else { return "记录有冲突或金额不确定，请先核对当前节点。" }
        guard !potMismatch else { return "记忆底池与行动推导底池不一致，核对前不输出单一确定底池的情景。" }
        guard let own, !own.folded, !own.allIn else { return "分析对象当前不能下注。" }
        guard active.count == 2, let opponent = opponents.first, !opponent.allIn else { return "当前并非双方均可行动的双人局面。" }
        guard snapshot.actorID == subjectID, !snapshot.roundComplete, !snapshot.handComplete else { return "本节需分析对象在当前节点实际轮到行动；请选择其行动前节点。" }
        guard snapshot.street != .preflop, snapshot.currentBet == 0,
              active.allSatisfy({ $0.streetContribution.units == 0 }) else { return "当前不是翻后尚无人下注的首次下注节点。" }
        guard let structure = potStructure, !structure.layers.isEmpty,
              structure.layers.allSatisfy({ Set($0.eligibleIDs) == Set([subjectID, opponent.id]) }), structure.refundUnits == 0 else {
            return "双方既有底池参与资格不同或池结构待核对，不能套用单一底池公式。"
        }
        guard let pot = snapshot.pot.units, pot > 0,
              let a = own.remaining.units, let b = opponent.remaining.units, a > 0, b > 0 else { return "当前底池或双方后手不足以建立下注情景。" }
        return nil
    }
    func scenario(_ text: String) -> (bet: Int64, result: PokerMath.CalledBetScenario)? {
        guard scenarioRestriction == nil, let amount = hand.configuration.chipUnit.parse(text), let bet = amount.units, bet > 0,
              let a = own?.remaining.units, let opponent = opponents.first, let b = opponent.remaining.units,
              let pot = snapshot.pot.units, bet >= hand.configuration.bigBlind || bet == a,
              let result = PokerMath.calledBet(pot: Double(pot), bettorStack: Double(a), callerStack: Double(b), bet: Double(bet), headsUpFirstBet: true) else { return nil }
        return (bet, result)
    }
}

struct AnalysisFactor: Identifiable {
    let title: String
    let detail: String
    var id: String { title }
}
enum AnalysisFactorGuide {
    static func factors(hand: HandRecord, snapshot: HandSnapshot, subjectID: UUID, eventID: UUID? = nil, after: Bool = false) -> [AnalysisFactor] {
        let context = AnalysisNodeContext(hand: hand, snapshot: snapshot, subjectID: subjectID, eventID: eventID, after: after)
        var factors: [AnalysisFactor] = []
        if snapshot.blocked {
            factors.append(.init(title: "先核对当前节点冲突", detail: "有冲突的事实不能支撑可靠的金额或权益结论；已知牌的成牌事实与依赖冲突的计算分开。"))
        }
        if context.potMismatch {
            factors.append(.init(title: "记忆底池与行动推导不一致", detail: "两份数值分别保留；核对前暂停依赖确定底池的 SPR、价格和情景，成牌与牌张权益不受此金额差异直接影响。"))
        }
        if snapshot.hasUncertainty {
            factors.append(.init(title: "金额仍有未知或近似项", detail: "未知不等于零。底池、后手及其依赖结果必须继承输入不确定性。"))
        }
        if context.active.count >= 3 {
            let actors = context.opponents.filter { !$0.allIn }.count
            factors.append(.init(title: "当前仍是 \(context.active.count) 人争池", detail: "全下玩家仍有池资格；另有 \(actors) 位未弃牌且未全下的对手。身后行动和不同主／边池资格会改变最终成本，不能把一次跟注价格当成所有人的无条件阈值。"))
        }
        if context.hasUnmatchedStreet {
            factors.append(.init(title: "本街投入尚未匹配", detail: "已投入筹码与可匹配部分需区分，当前不直接用下注后的剩余筹码除以旧底池。仅剩一方的顶层投入需要退回，不算可争夺底池。"))
        }
        if let own = context.own, own.folded {
            factors.append(.init(title: "分析对象在此时点已弃牌", detail: "其手牌仍可用于学习当前成牌，但不能再获得本节点底池权益。"))
        } else if snapshot.actorID != subjectID {
            factors.append(.init(title: "查看对象并非当前行动者", detail: "查看其他玩家不会改变实际行动顺序。本页不把其视为当前可以下注的人。"))
        }
        if !snapshot.hasUncertainty, !snapshot.blocked, !context.potMismatch, !context.hasUnmatchedStreet, let own = context.own?.remaining.units {
            for opponent in context.opponents {
                if let remaining = opponent.remaining.units,
                   let spr = PokerMath.spr(effectiveStackAtSameInstant: Double(min(own, remaining)), potAtSameInstant: context.commonPot(with: opponent.id)), spr >= 5 {
                    factors.append(.init(title: "对 \(context.name(opponent.id)) 的 SPR 为 \(String(format: "%.2f", spr))", detail: "当前有效后手相对共同底池较深；尚未发完牌时，后续街次和投入仍会影响决策。该比值不是自动下注建议。"))
                    break
                }
            }
        }
        let ranks = snapshot.board.map(\.rank)
        if Set(ranks).count < ranks.count {
            factors.append(.init(title: "公共牌已有对子", detail: "这是牌面事实；葫芦或四条路径是否相关还取决于具体手牌与范围，不能仅据牌面对行动评分。"))
        }
        if CardSuit.allCases.contains(where: { suit in snapshot.board.filter { $0.suit == suit }.count >= 3 }) {
            factors.append(.init(title: "公共牌至少三张同花色", detail: "同花路径需要结合己方手牌与已知死牌；成同花不必然领先于对手。"))
        }
        if snapshot.street != .river {
            factors.append(.init(title: "公共牌尚未发完", detail: "改善概率与胜率不同。只使用此时点已知牌，不能把未来转河牌提前计入当前判断。"))
        }
        if factors.isEmpty {
            factors.append(.init(title: "结论依赖当前手牌与范围条件", detail: "本页提供事实、条件计算与教学检查；不会按模板一致程度判定真实决策对错。"))
        }
        return factors
    }
}
