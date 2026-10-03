import SwiftUI

private enum HomeRoute: Hashable { case hand(UUID), session(UUID), reviews }
private enum RootTab: Hashable { case hands, statistics, preferences }

private enum HandListStatus: String {
    case draft = "草稿", needsCorrection = "待修正", pendingSettlement = "待结算", settled = "已结算"

    init(_ hand: HandRecord) {
        let projection = HandReducer.project(hand)
        let latest = projection.latest
        // A terminal snapshot can still retain conflicting or incomplete later facts.
        if latest.blocked || !projection.issues.isEmpty || latest.hasBoardGap {
            self = .needsCorrection
        } else if hand.settlement?.isCurrent(for: hand) == true {
            self = .settled
        } else if latest.handComplete || (latest.street == .river && latest.roundComplete) {
            self = .pendingSettlement
        } else {
            self = .draft
        }
    }

    var color: Color {
        switch self {
        case .draft: HandStyle.muted
        case .needsCorrection: HandStyle.red
        case .pendingSettlement: HandStyle.gold
        case .settled: HandStyle.green
        }
    }
}

struct HandListView: View {
    @StateObject private var store = LocalStore()
    @State private var path: [HomeRoute] = []
    @State private var showingSetup = false
    @State private var showingSessionSetup = false
    @State private var selectedTab = RootTab.hands
    @State private var statisticsHand: UUID?
    @State private var statisticsNavigationID = UUID()
    @State private var restored = false
    @State private var deleteTarget: HandRecord?
    @State private var error: String?

    private var independentHands: [HandRecord] {
        let sessionIDs = Set(store.sessions.flatMap { $0.hands.map(\.handID) })
        return store.hands.filter { !sessionIDs.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        TabView(selection: $selectedTab) {
            handsNavigation
                .tabItem { Label("牌局", systemImage: "rectangle.stack") }
                .tag(RootTab.hands)
            NavigationStack {
                ReviewStatisticsView(store: store) { handID in statisticsHand = handID }
                    .navigationDestination(item: $statisticsHand) { id in
                        HandWorkspaceView(handID: id, store: store)
                    }
            }
            .id(statisticsNavigationID)
            .tabItem { Label("统计", systemImage: "chart.bar") }
            .tag(RootTab.statistics)
            PreferencesView(store: store, showsDoneButton: false, onDataReplaced: resetNavigationAfterDataReplacement)
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(RootTab.preferences)
        }
        .tint(HandStyle.green)
        .toolbarBackground(HandStyle.canvas, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    private var handsNavigation: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("每一手，都有值得回看的决定。")
                            .font(.title2.weight(.semibold)).foregroundStyle(HandStyle.ink)
                        Text("记录事实，保留疑问，逐步还原牌局。")
                            .font(.subheadline).foregroundStyle(HandStyle.muted)
                    }.padding(.top, 12)
                    if let message = store.saveError {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(HandStyle.red).handPanel()
                        if store.requiresRecovery {
                            Button("打开数据恢复") { selectedTab = .preferences }.buttonStyle(.borderedProminent)
                        }
                    }
                    Button { showingSetup = true } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "plus").font(.title2).frame(width: 44, height: 44)
                                .background(.white.opacity(0.15), in: Circle())
                            VStack(alignment: .leading, spacing: 5) {
                                Text("历史牌局复盘").font(.headline)
                                Text("新建一手 · 从记得的事实开始").font(.subheadline).opacity(0.85)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }.padding(20).foregroundStyle(.white)
                            .background(HandStyle.green, in: RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(.plain).disabled(store.requiresRecovery)
                    Button { showingSessionSetup = true } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "person.3.sequence").font(.title2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("实时牌局分析").font(.headline)
                                Text("连续记录 · 教学与学习场次").font(.subheadline).foregroundStyle(HandStyle.muted)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }.handPanel()
                    }.buttonStyle(.plain).disabled(store.requiresRecovery)
                    HStack(spacing: 12) {
                        Button { path.append(.reviews) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Label("回顾与待办", systemImage: "bookmark")
                                Text("\(store.nodeAnnotations.filter { $0.reviewStatus == "pending" }.count) 个待复盘节点")
                                    .font(.caption).foregroundStyle(HandStyle.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading).handPanel()
                        }.buttonStyle(.plain)
                        Button {
                            statisticsHand = nil
                            statisticsNavigationID = UUID()
                            selectedTab = .statistics
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Label("基础统计", systemImage: "chart.bar")
                                Text("连续场次与精选复盘分开")
                                    .font(.caption).foregroundStyle(HandStyle.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading).handPanel()
                        }.buttonStyle(.plain)
                    }
                    if !store.sessions.isEmpty {
                        Text("连续场次").font(.title3.weight(.semibold))
                        ForEach(store.sessions.sorted { $0.updatedAt > $1.updatedAt }) { session in
                            Button { openSession(session) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(session.title).font(.headline)
                                        Text("\(session.status == .active ? "进行中" : "已结束") · \(session.hands.count) 手")
                                            .font(.subheadline).foregroundStyle(HandStyle.muted)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }.handPanel()
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Text("独立牌局复盘").font(.title3.weight(.semibold))
                        Spacer()
                        Text("\(independentHands.count) 手").font(.subheadline).foregroundStyle(HandStyle.muted)
                    }
                    if independentHands.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "rectangle.stack").font(.largeTitle).foregroundStyle(HandStyle.muted)
                            Text("还没有记录").font(.headline)
                            Text("创建历史牌局后，录入会自动保存在本机。\n未知信息可以保留，之后再补充。")
                                .font(.subheadline).foregroundStyle(HandStyle.muted).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 30).handPanel()
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(independentHands) { hand in
                                Button { open(hand) } label: { row(hand) }.buttonStyle(.plain)
                                    .contextMenu { Button("删除牌局", role: .destructive) { deleteTarget = hand } }
                            }
                        }
                    }
                }.padding(20)
            }
            .background(HandStyle.canvas).foregroundStyle(HandStyle.ink)
            .navigationTitle("Tablewise")
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .hand(let id): HandWorkspaceView(handID: id, store: store)
                case .session(let id): SessionDetailView(sessionID: id, store: store) { handID in path.append(.hand(handID)) }
                case .reviews: ReviewQueueView(store: store) { handID in path.append(.hand(handID)) }
                }
            }
            .sheet(isPresented: $showingSetup) {
                HandSetupView(store: store) { id in path = [.hand(id)] }
            }
            .sheet(isPresented: $showingSessionSetup) {
                HandSetupView(store: store, createSession: true) { id in path = [.hand(id)] }
            }
            .task {
                guard !restored else { return }; restored = true
                if let id = store.selection.lastHandID, store.hands.contains(where: { $0.id == id }) { path = [.hand(id)] }
                else if let id = store.selection.lastSessionID, store.sessions.contains(where: { $0.id == id }) { path = [.session(id)] }
            }
            .alert("删除这手牌局？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
                Button("取消", role: .cancel) { deleteTarget = nil }
                Button("删除", role: .destructive) {
                    guard let hand = deleteTarget else { return }
                    do { try store.delete(id: hand.id) } catch { self.error = error.localizedDescription }
                    deleteTarget = nil
                }
            } message: { Text("牌局及关联标记会从本机删除。已有导出备份不受影响。") }
            .alert("未能完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }.tint(HandStyle.green)
    }
    private func resetNavigationAfterDataReplacement() {
        // A backup replacement can reuse IDs with entirely different facts. Drop all hidden destinations.
        path = []
        statisticsHand = nil
        statisticsNavigationID = UUID()
        restored = true
    }

    private func row(_ hand: HandRecord) -> some View {
        let status = HandListStatus(hand)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(hand.title).font(.headline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(HandStyle.muted)
            }
            HStack(spacing: 8) {
                Text("\(hand.players.count) 人")
                Text("·")
                Text("\(hand.configuration.chipUnit.format(units: hand.configuration.smallBlind)) / \(hand.configuration.chipUnit.format(units: hand.configuration.bigBlind))")
                Text("·")
                Text("\(hand.events.filter { !$0.kind.isForced && $0.kind != .deal }.count) 次行动")
            }.font(.subheadline).foregroundStyle(HandStyle.muted)
            HStack {
                Text(status.rawValue).font(.caption.weight(.medium)).foregroundStyle(status.color)
                    .padding(.horizontal, 9).padding(.vertical, 4).background(HandStyle.canvas, in: Capsule())
                    .accessibilityLabel("记录状态：\(status.rawValue)")
                Spacer()
                Text(hand.updatedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(HandStyle.muted)
            }
        }.handPanel()
    }
    private func openSession(_ session: SessionRecord) {
        do {
            try store.updateSelection(StoreSelection(lastHandID: nil, selectedEventID: nil, lastSessionID: session.id))
            path.append(.session(session.id))
        } catch { self.error = error.localizedDescription }
    }
    private func open(_ hand: HandRecord) {
        do {
            let eventID = store.selection.lastHandID == hand.id ? store.selection.selectedEventID : hand.events.last?.id
            try store.updateSelection(StoreSelection(lastHandID: hand.id, selectedEventID: eventID))
            path.append(.hand(hand.id))
        } catch { self.error = error.localizedDescription }
    }
}
