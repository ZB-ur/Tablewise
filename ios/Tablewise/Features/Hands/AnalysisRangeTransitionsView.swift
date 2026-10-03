import SwiftUI

struct AnalysisRangeTransitionsView: View {
    let request: Result<EquityRequest, Error>
    let subjectID: UUID
    let inputStamp: String
    let assumptions: [String]
    @State private var report: RangeTransitionReport?
    @State private var worker: Task<RangeTransitionReport, Error>?
    @State private var completedStamp = ""
    @State private var active = ""
    @State private var status = "待计算"
    @State private var running = false
    @State private var retry = 0
    private var taskID: String { inputStamp + ":\(retry)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("范围条件 · 牌力变化").font(.headline)
                    Text("使用节点当前明确的手牌与范围，联合排除重复牌后抽取下一张和河牌。不读取未来公共牌，不预测下注。")
                        .font(.caption).foregroundStyle(HandStyle.muted)
                    ForEach(Array(assumptions.enumerated()), id: \.offset) { _, text in Text(text).font(.caption) }
                }.handPanel()
                if let report, completedStamp == inputStamp {
                    summary(report)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("具体下一张牌").font(.headline)
                        Text("每行是在该牌实际被抽到的样本中，转为独自领先／失去份额的比例。观察次数不同，不可将各行百分比直接相加；未抽到的牌不列出，也不视为不可能。")
                            .font(.caption).foregroundStyle(HandStyle.muted)
                        ForEach(report.cards) { card in
                            HStack(alignment: .top) {
                                PlayingCard(value: cardLabel(card.card), small: true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("转为领先 \(percent(card.leadProbability)) · 失去份额 \(percent(card.dangerProbability))").font(.caption)
                                    Text("该牌观察 \(card.observations) 次").font(.caption2).foregroundStyle(HandStyle.muted)
                                }
                                Spacer()
                            }
                        }
                    }.handPanel()
                    Button("重新计算") { retry += 1 }.font(.subheadline)
                } else if active == taskID && running {
                    HStack { ProgressView(); Text("抽取合法联合手牌与后续公共牌…").font(.subheadline); Spacer(); Button("取消") { worker?.cancel() } }.handPanel()
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(active == taskID ? status : "输入已变化，旧结果失效").font(.subheadline)
                        Button("重试") { retry += 1 }.font(.subheadline)
                    }.handPanel()
                }
            }.padding(16)
        }.background(HandStyle.canvas).foregroundStyle(HandStyle.ink)
            .navigationTitle("范围条件危险牌").navigationBarTitleDisplayMode(.inline)
            .task(id: taskID) { await calculate() }
            .onDisappear { worker?.cancel() }
    }
    private func summary(_ report: RangeTransitionReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(report.potID) · 联合事件估计").font(.headline)
            Text("只比较该池有资格的玩家；其他范围玩家仍参与牌张排除。").font(.caption).foregroundStyle(HandStyle.muted)
            HStack { stat("下一张转为独自领先", report.nextLeadProbability); Spacer(); stat("河牌时转为独自领先", report.riverLeadProbability) }
            HStack { stat("下一张失去份额", report.nextDangerProbability); Spacer(); stat("河牌时失去份额", report.riverDangerProbability) }
            Text("转为领先：该次样本当前并非独赢，后续变为独赢。失去份额：该次样本当前已有独赢或平分份额，后续份额减少。以上是这些变化发生的联合概率，不是给定已领先后的条件胜率，也不是必胜 Outs。")
                .font(.caption).foregroundStyle(HandStyle.muted)
            Text("\(report.samples) 个合法样本 · \(report.attempts) 次尝试 · \(String(format: "%.2f", report.elapsedSeconds)) 秒")
                .font(.caption.monospacedDigit())
            Text("种子 \(String(report.seed, radix: 16)) · 模拟估计，0 次命中不能证明概率为零。")
                .font(.caption2).foregroundStyle(HandStyle.muted)
            if report.reachedBudget { Text("达到时间或尝试次数预算，以上基于已完成样本。").font(.caption).foregroundStyle(HandStyle.gold) }
            Text("下一张领先后仍可能在河牌失去领先；河牌数据只描述最终时点。模型依赖你给定的范围，没有策略置信分数或一般情景 EV。")
                .font(.caption).foregroundStyle(HandStyle.muted)
        }.handPanel()
    }
    private func calculate() async {
        let token = taskID
        worker?.cancel(); report = nil; running = false; active = token
        do {
            var input = try request.get()
            guard [3, 4].contains(input.board.count) else { throw RangeAnalysisInputError.invalid("需要当前翻牌或转牌；翻前缺少可比较成牌，河牌已无后续公共牌") }
            input.settings.sampleCount = 12_000
            input.settings.maximumSeconds = 12
            let immutable = input
            let subject = subjectID.uuidString
            let task = Task.detached(priority: .userInitiated) { try RangeTransitionEngine.calculate(immutable, subjectID: subject) }
            worker = task; running = true
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, active == token else { return }
            report = value; completedStamp = inputStamp; worker = nil; running = false
        } catch {
            guard !Task.isCancelled, active == token else { return }
            status = error is CancellationError ? "计算已取消" : error.localizedDescription; worker = nil; running = false
        }
    }
    private func cardLabel(_ card: Int) -> String { RangePlan.rankLabel(card / 4 + 2) + CardSuit.allCases[card % 4].symbol }
    private func percent(_ value: Double) -> String { String(format: "≈%.1f%%", value * 100) }
    private func stat(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption2).foregroundStyle(HandStyle.muted); Text(percent(value)).font(.subheadline.monospacedDigit().weight(.semibold)) }
    }
}
