import SwiftUI

/// The caller supplies either the latest entry snapshot or one specific replay node.
/// Opponents' recorded cards are excluded only in reveal mode; future boards never enter this input.
struct HandOutsContext: Sendable {
    let hand: HandRecord
    let snapshot: HandSnapshot
    let subjectID: UUID?
    let reveal: Bool
    let after: Bool
    let eventID: UUID?

    var subject: HandPlayer? { hand.players.first { $0.id == subjectID } }
    var fingerprint: String {
        let cards = hand.players.map { "\($0.id):\($0.holeCards.map(\.id).joined(separator: ","))" }.joined(separator: ";")
        return "\(hand.id):\(hand.revision):\(subjectID?.uuidString ?? "none"):\(reveal):\(after):\(eventID?.uuidString ?? "initial"):\(snapshot.street):\(snapshot.displayStreet):\(snapshot.board.map(\.id)):\(snapshot.hasBoardGap):\(snapshot.blocked):\(snapshot.players.map { "\($0.id):\($0.folded)" }):\(cards)"
    }
    var isRiver: Bool { !snapshot.blocked && !snapshot.hasBoardGap && snapshot.board.count == 5 }
    var unavailableMessage: String? {
        guard subject != nil else { return "未设置自己 · 改善牌待明确对象" }
        guard !snapshot.hasBoardGap else { return "公共牌缺项 · 改善牌未知" }
        guard !snapshot.blocked else { return "记录待修正 · 改善分析暂停" }
        if isRiver { return "河牌无后续公共牌 · 改善牌不适用" }
        guard subject?.holeCards.count == 2 else { return "手牌未齐 · 改善牌未知" }
        guard [3, 4].contains(snapshot.board.count) else { return "待录入翻牌 · 改善牌未知" }
        return nil
    }

    /// Shares the established advanced-page exclusion and comparison rules.
    func inputs() -> (hole: [Int], board: [Int], dead: [Int], opponents: [[Int]]) {
        let opponents = snapshot.players.filter { !$0.folded && $0.id != subjectID }
        let recorded = opponents.compactMap { opponent in hand.players.first { $0.id == opponent.id } }
        let canCompare = reveal && !recorded.isEmpty && recorded.count == opponents.count && recorded.allSatisfy { $0.holeCards.count == 2 }
        let comparisonIDs = canCompare ? Set(recorded.map(\.id)) : Set<UUID>()
        return (subject?.holeCards.map(\.analysisIndex) ?? [], snapshot.board.map(\.analysisIndex),
                reveal ? hand.players.filter { $0.id != subjectID && !comparisonIDs.contains($0.id) }.flatMap { $0.holeCards.map(\.analysisIndex) } : [],
                canCompare ? recorded.map { $0.holeCards.map(\.analysisIndex) } : [])
    }
}

struct HandOutsSummary: View {
    let context: HandOutsContext
    let isLatest: Bool
    @State private var report: OutsReport?
    @State private var reportToken = ""
    @State private var message: String?
    @State private var running = false
    @State private var worker: Task<OutsReport, Error>?
    @State private var retry = 0
    @State private var details = false

    private var token: String { context.fingerprint + ":\(retry)" }
    private var currentReport: OutsReport? { reportToken == token ? report : nil }
    private var contextLabel: String {
        isLatest ? "自己 · 最新记录 · 决策视角" : "\(context.subject?.name ?? "对象未知") · \(context.snapshot.displayStreet.title) · 行动\(context.after ? "后" : "前")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { details = true } label: {
                HStack(spacing: 6) {
                    Text("成牌改善").font(.caption.weight(.semibold))
                    Text(isLatest ? "自己 · 最新" : context.subject?.name ?? "对象未知")
                        .font(.caption2).foregroundStyle(HandStyle.muted)
                    Spacer()
                    Text("详情").font(.caption)
                    Image(systemName: "chevron.right").font(.caption2)
                }.frame(minHeight: 30)
            }.buttonStyle(.plain).disabled(context.subjectID == nil)
                .accessibilityLabel("改善牌详情，\(contextLabel)")
            if let report = currentReport {
                Text(report.events.filter { [.straight, .flush, .higherCategory].contains($0.target) }.map(targetSummary).joined(separator: " · "))
                    .font(.caption2).foregroundStyle(HandStyle.muted)
                HStack(alignment: .firstTextBaseline) {
                    Text("合并下一张 \(report.combinedNextCards.count)/\(report.unseenCount) · \(probability(Double(report.combinedNextCards.count) / Double(report.unseenCount)))")
                    Spacer(minLength: 5)
                    Text("截至河牌 \(probability(report.combinedByRiverProbability))")
                }.font(.caption.monospacedDigit().weight(.medium))
                Text("重叠已去重 · 非胜率 · 后门两张另列详情")
                    .font(.caption2).foregroundStyle(HandStyle.muted)
            } else if let unavailable = context.unavailableMessage {
                Text(unavailable).font(.caption).foregroundStyle(HandStyle.muted)
            } else if reportToken == token && running {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("正在计算改善牌…").font(.caption); Spacer(); Button("取消") { worker?.cancel() }.font(.caption) }
            } else {
                HStack {
                    Text(reportToken == token ? message ?? "待计算" : "改善牌待计算 · 旧结果已失效").font(.caption).foregroundStyle(HandStyle.muted)
                    Spacer()
                    Button("重试") { retry += 1 }.font(.caption)
                }
            }
        }
        .task(id: token) { await calculate() }
        .onDisappear { worker?.cancel() }
        .sheet(isPresented: $details) {
            if let subjectID = context.subjectID {
                NavigationStack {
                    AnalysisAdvancedPage(hand: context.hand, snapshot: context.snapshot, subjectID: subjectID,
                                         reveal: context.reveal, after: context.after, eventID: context.eventID,
                                         focusesOuts: true, contextLabel: contextLabel)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { details = false } } }
                }
            }
        }
    }

    private func targetSummary(_ event: ImprovementEvent) -> String {
        let title: String
        switch event.target {
        case .straight: title = "组成顺子"
        case .flush: title = "组成同花"
        default: title = "升高类别"
        }
        return "\(title) \(event.alreadyAchieved ? "已成" : "\(event.nextCards.count)张")"
    }
    private func probability(_ value: Double) -> String { String(format: "%.2f%%", value * 100) }
    private func calculate() async {
        let current = token
        worker?.cancel(); reportToken = current; report = nil; message = nil; running = false
        guard context.unavailableMessage == nil else { return }
        let input = context.inputs()
        let task = Task.detached(priority: .userInitiated) {
            try PokerOuts.analyze(hole: input.hole, board: input.board, deadCards: input.dead, knownOpponents: input.opponents)
        }
        worker = task; running = true
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, reportToken == current, token == current else { return }
            report = result; running = false; worker = nil
        } catch {
            guard !Task.isCancelled, reportToken == current, token == current else { return }
            message = error is CancellationError ? "计算已取消" : error.localizedDescription
            running = false; worker = nil
        }
    }
}
