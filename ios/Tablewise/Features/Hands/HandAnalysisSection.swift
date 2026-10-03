import SwiftUI

/// Normalize zero at the displayed precision without changing the calculated EV.
enum ConditionalCallEVDisplay {
    static func text(_ value: Double) -> String {
        let formatted = String(format: "%+.2f", value)
        return formatted == "-0.00" || formatted == "+0.00" ? "0.00" : formatted
    }
}

/// Receives an already selected before/after snapshot; never reads future board events.
struct HandAnalysisSection: View {
    let hand: HandRecord
    let snapshot: HandSnapshot
    let subjectID: UUID
    let reveal: Bool
    let eventID: UUID?
    let after: Bool
    @ObservedObject var store: LocalStore
    let transientPlans: [String: RangePlan]

    @State private var activeID = ""
    @State private var result: EquityResult?
    @State private var message: String?
    @State private var running = false
    @State private var retry = 0
    @State private var worker: Task<EquityResult, Error>?

    init(hand: HandRecord, snapshot: HandSnapshot, subjectID: UUID, reveal: Bool,
         eventID: UUID?, after: Bool, store: LocalStore, transientPlans: [String: RangePlan] = [:]) {
        self.hand = hand; self.snapshot = snapshot; self.subjectID = subjectID; self.reveal = reveal
        self.eventID = eventID; self.after = after; self.store = store; self.transientPlans = transientPlans
    }

    private var subject: HandPlayer? { hand.players.first { $0.id == subjectID } }
    private var board: [Int] { snapshot.board.map(\.analysisIndex) }
    private var hole: [Int] { subject?.holeCards.map(\.analysisIndex) ?? [] }
    private var opponentsKnown: [Int] {
        reveal ? hand.players.filter { $0.id != subjectID }.flatMap { $0.holeCards.map(\.analysisIndex) } : []
    }
    private var eligible: [PlayerSnapshot] { snapshot.players.filter { !$0.folded } }
    private var contextPlans: [RangePlan] {
        guard let eventID else { return [] }
        return store.rangePlans.filter {
            $0.handID == hand.id && $0.eventID == eventID && $0.subjectID == subjectID
                && $0.after == after && $0.reveal == reveal && $0.resolvedScope == .decision
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private var contextDrafts: [RangePlan] {
        guard let eventID else { return [] }
        return transientPlans.values.filter {
            $0.handID == hand.id && $0.eventID == eventID && $0.subjectID == subjectID
                && $0.after == after && $0.reveal == reveal && $0.resolvedScope == .decision
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private func candidatePlans(for target: UUID) -> [RangePlan] {
        let drafts = contextDrafts.filter { $0.targetPlayerID == target }
        // An explicit temporary hypothesis immediately supersedes saved selection,
        // including when the draft is incomplete or empty; never fall back silently.
        return drafts.isEmpty ? contextPlans.filter { $0.targetPlayerID == target && $0.isActive } : drafts
    }
    private func isTemporary(_ plan: RangePlan) -> Bool {
        contextDrafts.contains(plan) && !contextPlans.contains(plan)
    }
    private var dependencyPlans: [RangePlan] {
        RangePlanDependencies.environment(saved: store.rangePlans, temporary: Array(transientPlans.values))
    }
    private var plansFingerprint: String {
        // Include weights and selection as well as revision; range changes need not touch hand.revision.
        return RangeAnalysisContext.fingerprint(plans: store.rangePlans.filter { $0.handID == hand.id }) + "|" + RangeAnalysisContext.fingerprint(plans: dependencyPlans.filter { $0.handID == hand.id }) + "|temporary:" + transientPlans.values.map { $0.id.uuidString }.sorted().joined(separator: ",")
    }
    private func usesKnownHand(_ id: UUID) -> Bool {
        (reveal || id == subjectID) && hand.players.first(where: { $0.id == id })?.holeCards.count == 2
    }
    private func selectedPlan(_ target: UUID) throws -> RangePlan {
        guard eventID != nil else { throw AnalysisInputError.message("尚未选择行动节点，范围待设定") }
        let selected = candidatePlans(for: target)
        guard selected.count == 1 else {
            throw AnalysisInputError.message("\(playerName(target.uuidString))：\(selected.isEmpty ? "尚未明确选择范围方案" : "存在多个启用方案，请明确选择一个")")
        }
        let plan = selected[0]
        guard plan.factRevision == hand.revision, plan.removedEvent == nil else {
            throw AnalysisInputError.message("\(plan.name)：事实版本已变化，请核对并重新保存范围")
        }
        guard plan.isValidWeights else { throw AnalysisInputError.message("\(plan.name)：范围权重无效") }
        return plan
    }
    private var fingerprint: String {
        let state = snapshot.players.map {
            "\($0.id):\($0.folded):\($0.allIn):\($0.remaining.units.map(String.init) ?? "?"):\($0.remaining.certainty):\($0.streetContribution.units.map(String.init) ?? "?"):\($0.streetContribution.certainty):\($0.totalContribution.units.map(String.init) ?? "?"):\($0.totalContribution.certainty)"
        }.joined(separator: ";")
        let cards = hand.players.map { "\($0.id):\($0.holeCards.map(\.id).joined(separator: ","))" }.joined(separator: ";")
        return "\(hand.id)|\(hand.revision)|\(subjectID)|\(reveal)|\(snapshot.street)|\(board)|\(state)|\(cards)|\(snapshot.actorID?.uuidString ?? "-")|\(snapshot.currentBet)|\(snapshot.pot.units.map(String.init) ?? "?")|\(snapshot.pot.certainty)|\(snapshot.blocked)|\(snapshot.roundComplete)|\(snapshot.handComplete)|\(eventID?.uuidString ?? "start")|\(after)|\(plansFingerprint)|\(retry)"
    }
    private var currentResult: EquityResult? { activeID == fingerprint ? result : nil }
    private var madeHand: PokerHandValue? {
        guard !snapshot.blocked, hole.count == 2 else { return nil }
        return try? PokerEvaluator.evaluate(hole + board)
    }
    private var draw: FlushImprovement? {
        guard !snapshot.blocked else { return nil }
        return try? PokerImprovement.flushDraw(hole: hole, board: board, otherKnownCards: opponentsKnown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            madeHandPanel
            equityPanel
            advancedPanel
        }
        .foregroundStyle(HandStyle.ink)
        .task(id: fingerprint) { await calculate() }
        .onDisappear { worker?.cancel() }
    }

    private var advancedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            let factors = AnalysisFactorGuide.factors(hand: hand, snapshot: snapshot, subjectID: subjectID, eventID: eventID, after: after)
            Label(factors[0].title, systemImage: "lightbulb").font(.subheadline.weight(.semibold))
            DisclosureGroup("查看依据") {
                Text(factors[0].detail).font(.caption).foregroundStyle(HandStyle.muted).padding(.top, 4)
            }.font(.caption)
            NavigationLink {
                AnalysisAdvancedPage(hand: hand, snapshot: snapshot, subjectID: subjectID, reveal: reveal, after: after, eventID: eventID)
            } label: {
                Label("改善牌、SPR 与下注情景", systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold))
            }
            NavigationLink {
                AnalysisRangeSensitivityView(hand: hand, snapshot: snapshot, subjectID: subjectID, eventID: eventID,
                                             after: after, reveal: reveal, store: store, transientPlans: transientPlans)
            } label: { Label("两方案真实权益比较", systemImage: "arrow.left.arrow.right").font(.subheadline.weight(.semibold)) }
            NavigationLink {
                AnalysisRangeTransitionsView(request: Result { try request() }, subjectID: subjectID,
                                             inputStamp: fingerprint, assumptions: analysisAssumptions)
            } label: { Label("范围条件下的反超与危险牌", systemImage: "rectangle.on.rectangle.angled").font(.subheadline.weight(.semibold)) }
        }.handPanel()
    }

    private var analysisAssumptions: [String] {
        eligible.map { player in
            let name = playerName(player.id.uuidString)
            if usesKnownHand(player.id) { return "\(name) · 当前视角已知手牌" }
            let plans = candidatePlans(for: player.id)
            guard plans.count == 1, let plan = plans.first else { return "\(name) · 范围待明确选择" }
            return "\(name) · \(plan.name) v\(plan.revision) · \(RangeCatalogRepository.bundled.sourceSummary(plan: plan, hand: hand))\(isTemporary(plan) ? " · 临时假设" : "")"
        }
    }

    private var madeHandPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("当前牌力", systemImage: "suit.club.fill").font(.headline)
                Spacer()
                Text(snapshot.displayStreet.title).font(.caption).foregroundStyle(HandStyle.muted)
            }
            if let value = madeHand {
                Text(value.category.title).font(.title2.weight(.semibold))
                HStack(spacing: 5) {
                    ForEach(value.bestFive, id: \.self) { card in PlayingCard(value: cardLabel(card), small: true) }
                }.accessibilityLabel("最佳五张：" + value.bestFive.map(cardLabel).joined(separator: "、"))
                if board.count == 5, let publicHand = try? PokerEvaluator.evaluate(board), publicHand == value {
                    Text("公共牌本身即可组成同等牌力").font(.caption).foregroundStyle(HandStyle.muted)
                }
            } else {
                Text(snapshot.blocked ? "行动或公共牌缺项；牌力待核对" : hole.count != 2 ? "待录入分析对象的两张手牌" : board.count < 3 ? "翻牌前尚无完整五张成牌" : "牌张待核对")
                    .font(.subheadline).foregroundStyle(HandStyle.muted)
            }
            Divider().overlay(HandStyle.line)
            if let draw {
                HStack {
                    Text("成同花 · \(draw.outs.count) 张改善牌").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(draw.unseenCount) 张未知牌").font(.caption).foregroundStyle(HandStyle.muted)
                }
                HStack(spacing: 24) {
                    metric("下一张", percent(draw.nextCardProbability))
                    if draw.cardsToCome == 2 { metric("截至河牌", percent(draw.byRiverProbability)) }
                }
                Text(draw.outs.map(cardLabel).joined(separator: "  ")).font(.caption.monospaced())
                Text("这是成同花事件概率，不是获胜概率；已排除当前视角的已知牌。")
                    .font(.caption).foregroundStyle(HandStyle.muted)
            } else {
                Text(snapshot.blocked ? "行动或公共牌缺项；改善牌待核对" : board.count == 5 ? "河牌无后续公共牌，改善概率不适用" : "同花听牌：\(hole.count == 2 && board.count >= 3 ? "当前无四张同花听牌，或牌张需核对" : "待补齐当前手牌和翻牌")")
                    .font(.caption).foregroundStyle(HandStyle.muted)
            }
        }.handPanel()
    }

    private var equityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("权益").font(.headline)
                Spacer()
                Text(reveal ? "揭牌视角" : "决策视角").font(.caption.weight(.medium)).foregroundStyle(HandStyle.green)
            }
            Text(reveal ? "使用当前公共牌与已录入手牌；已知弃牌仅作死牌排除。" : "仅使用分析对象的手牌；其他玩家需明确范围假设。")
                .font(.caption).foregroundStyle(HandStyle.muted)
            if let remembered = hand.rememberedPot(nodeEventID: eventID, after: after) {
                Text("记忆底池 \(hand.configuration.chipUnit.format(remembered.amount)) · 推导底池 \(hand.configuration.chipUnit.format(snapshot.pot))")
                    .font(.caption).foregroundStyle(HandStyle.muted)
                if hand.potNeedsReconciliation(nodeEventID: eventID, after: after) {
                    Text("底池差异待核对，价格与 EV 暂停；牌张权益仍按当前手牌与范围计算。")
                        .font(.caption).foregroundStyle(HandStyle.gold)
                }
            }
            rangeSources
            if let result = currentResult {
                ForEach(result.pots, id: \.potID) { pot in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pot.potID).font(.subheadline.weight(.semibold))
                        ForEach(pot.shares, id: \.playerID) { share in
                            HStack(alignment: .firstTextBaseline) {
                                Text(playerName(share.playerID)).font(.subheadline.weight(share.playerID == subjectID.uuidString ? .semibold : .regular))
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(percent(share.equity, simulated: result.method == .monteCarlo)).font(.headline.monospacedDigit())
                                    Text("独赢 \(percent(share.winProbability, simulated: result.method == .monteCarlo)) · 平局 \(percent(share.tieProbability, simulated: result.method == .monteCarlo))")
                                        .font(.caption2).foregroundStyle(HandStyle.muted)
                                }
                            }
                        }
                    }
                }
                Text("\(result.method == .exact ? "精确枚举" : "模拟估计") · \(result.samples) \(result.method == .exact ? "个局面" : "个样本") · \(String(format: "%.2f", result.elapsedSeconds)) 秒")
                    .font(.caption).foregroundStyle(HandStyle.muted)
                if result.method == .monteCarlo {
                    Text("固定种子 \(String(result.seed, radix: 16)) · \(result.attempts) 次抽样尝试")
                        .font(.caption2).foregroundStyle(HandStyle.muted)
                }
                if result.completion != .complete {
                    Text(result.completion == .timeBudget ? "达到时间上限，以上为已完成样本的估计。" : "达到抽样次数上限，以上为已完成样本的估计。")
                        .font(.caption).foregroundStyle(HandStyle.gold)
                }
                Text("权益包含平分份额；实际结算零头需按筹码单位另行分配。")
                    .font(.caption).foregroundStyle(HandStyle.muted)
                conditionalPrice(result)
                Button("重新计算", systemImage: "arrow.clockwise") { retry += 1 }.font(.subheadline)
            } else if activeID == fingerprint && running {
                HStack { ProgressView(); Text("正在计算当前节点…").font(.subheadline); Spacer(); Button("取消") { worker?.cancel() } }
            } else {
                Text(activeID == fingerprint ? message ?? "待计算" : "输入已变化，旧结果已失效")
                    .font(.subheadline).foregroundStyle(HandStyle.muted)
                if activeID == fingerprint, message != nil {
                    Button("重试", systemImage: "arrow.clockwise") { retry += 1 }.font(.subheadline)
                }
            }
        }.handPanel()
    }

    private var rangeSources: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(eligible) { player in
                if usesKnownHand(player.id) {
                    Text("\(playerName(player.id.uuidString)) · 已录入手牌")
                        .font(.caption).foregroundStyle(HandStyle.muted)
                } else {
                    let selected = candidatePlans(for: player.id)
                    if selected.count == 1, let plan = selected.first {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(playerName(player.id.uuidString)) · \(plan.name) · v\(plan.revision)")
                            ForEach(RangePlanDependencies.issues(for: plan, hand: hand, plans: dependencyPlans, savedPlans: store.rangePlans, temporaryPlanIDs: Set(transientPlans.values.map(\.id))), id: \.self) { issue in
                                Text("失效：" + issue).foregroundStyle(HandStyle.red)
                            }
                            Text("\(isTemporary(plan) ? "临时假设 · " : "")\(RangeCatalogRepository.bundled.sourceSummary(plan: plan, hand: hand)) · 事实 v\(plan.factRevision)\(plan.factRevision == hand.revision && plan.removedEvent == nil ? "" : " · 已过期")")
                                .foregroundStyle(plan.factRevision == hand.revision && plan.removedEvent == nil ? HandStyle.muted : HandStyle.gold)
                        }.font(.caption)
                    } else {
                        Text("\(playerName(player.id.uuidString)) · \(selected.isEmpty ? "未选择范围方案" : "范围选择冲突")")
                            .font(.caption).foregroundStyle(HandStyle.gold)
                    }
                }
            }
        }
    }

    @ViewBuilder private func conditionalPrice(_ result: EquityResult) -> some View {
        if let input = try? analysisInput() {
            if let price = input.callPrice,
               let share = result.pots.first?.shares.first(where: { $0.playerID == subjectID.uuidString }),
               let ev = PokerMath.conditionalCallEV(equity: share.equity, price: price), let unit = hand.configuration.chipUnit.value {
                Divider()
                Text("跟注价格 · 有限跟注模型").font(.subheadline.weight(.semibold))
                Text("跟注 \(NSDecimalNumber(decimal: Decimal(price.cost) * unit).stringValue) · 跟后池 \(NSDecimalNumber(decimal: Decimal(price.contestablePotAfterCall) * unit).stringValue) · 盈亏平衡 \(percent(price.breakEvenEquity))")
                    .font(.caption)
                Text("相对弃牌的跟注 EV：\(ConditionalCallEVDisplay.text(ev * NSDecimalNumber(decimal: unit).doubleValue))")
                    .font(.subheadline.monospacedDigit())
                Text(input.priceRestriction).font(.caption).foregroundStyle(HandStyle.muted)
            } else {
                Text(input.priceRestriction).font(.caption).foregroundStyle(HandStyle.muted)
            }
        }
    }

    private func analysisInput() throws -> RangeAnalysisInput {
        var overrides: [UUID: RangePlan] = [:]
        for player in eligible where !usesKnownHand(player.id) {
            overrides[player.id] = try selectedPlan(player.id)
        }
        return try RangeAnalysisContext.build(hand: hand, snapshot: snapshot, subjectID: subjectID,
                                               eventID: eventID, after: after, reveal: reveal,
                                               plans: dependencyPlans, overrides: overrides, savedPlans: store.rangePlans, temporaryPlanIDs: Set(transientPlans.values.map(\.id)))
    }

    private func request() throws -> EquityRequest { try analysisInput().request }

    private func calculate() async {
        let token = fingerprint
        worker?.cancel(); activeID = token; result = nil; message = nil; running = false
        do {
            let input = try request()
            running = true
            let task = Task.detached(priority: .userInitiated) { try EquityEngine.calculateSynchronously(input) }
            worker = task
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, activeID == token else { return }
            result = value; running = false; worker = nil
        } catch {
            guard !Task.isCancelled, activeID == token else { return }
            message = error is CancellationError ? "计算已取消，可重试" : error.localizedDescription
            running = false; worker = nil
        }
    }

    private func cardLabel(_ index: Int) -> String {
        let rank = index / 4 + 2
        return ([11: "J", 12: "Q", 13: "K", 14: "A"][rank] ?? String(rank)) + ["♣", "♦", "♥", "♠"][index % 4]
    }
    private func playerName(_ id: String) -> String { hand.players.first { $0.id.uuidString == id }?.name ?? "玩家" }
    private func percent(_ value: Double, simulated: Bool = false) -> String { String(format: simulated ? "≈%.1f%%" : "%.2f%%", value * 100) }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption).foregroundStyle(HandStyle.muted); Text(value).font(.title3.monospacedDigit().weight(.semibold)) }
    }
}

private enum AnalysisInputError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
