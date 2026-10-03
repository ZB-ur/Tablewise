import SwiftUI

struct HandWorkspaceView: View {
    let handID: UUID
    @ObservedObject var store: LocalStore
    @State private var selectedID: UUID?
    @State private var researchBaseline: ResearchNodeBaseline?
    @State private var filterPlayer: UUID?
    @State private var filterStreet: HandStreet?
    @State private var expanded = false
    @State private var detail = false
    @State private var fullAnalysis = false
    @State private var detailDetent: PresentationDetent = .fraction(0.73)
    @State private var detailScrollPage = 0
    @State private var after = false
    @State private var subject: UUID?
    @State private var reveal = false
    @State private var analysisRevealed = false
    @State private var transientPlans: [String: RangePlan] = [:]
    @State private var rangeWorkspaceStates: [HandRangeWorkspaceIdentity: HandRangeWorkspaceState] = [:]
    @State private var actionEditor = false
    @State private var editorWasFull = false
    @State private var editingEvent: HandEvent?
    @State private var insertionIndex: Int?
    @State private var incompleteEntry = false
    @State private var annotationEvent: HandEvent?
    @State private var showSettlement = false
    @State private var editConfiguration = false
    @State private var showSession = false
    @State private var destinationHandID: UUID?
    @State private var navigateHand = false
    @State private var cardTarget: CardTarget?
    @State private var cardEditorContext: CardEditorContext?
    @State private var undoRecords: [HandUndoRecord] = []
    @State private var error: String?
    @State private var feedback: String?
    @State private var notes = false
    @State private var rememberedPotEditor = false
    @State private var correctionPreview: SessionCorrectionPreview?
    @State private var boardChangePreview: HandBoardChangePreview?
    @State private var participantCounts: HandParticipantCounts?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct ResearchNodeBaseline {
        let eventID: UUID
        let revision: Int
        let eventIDs: Set<UUID>
    }

    private var nodeEditorPresented: Bool { actionEditor || cardTarget != nil || cardEditorContext != nil }
    private var currentPresentationHost: PresentationHost { detail ? (fullAnalysis ? .analysis : .detail) : .workspace }
    private var hand: HandRecord? { store.hands.first { $0.id == handID } }
    private var session: SessionRecord? { store.sessions.first { $0.hands.contains { $0.handID == handID } } }
    var body: some View {
        Group {
            if let hand {
                workspace(hand)
            } else { ContentUnavailableView("牌局不可用", systemImage: "rectangle.stack") }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: selectedID) { _, id in
            analysisRevealed = false
            if detail, let hand { resetResearchBaseline(hand) }
            do { try store.updateSelection(StoreSelection(lastHandID: handID, selectedEventID: id)) }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: detail) { _, presented in
            if presented, let hand { resetResearchBaseline(hand) }
            else if !presented { researchBaseline = nil }
        }
        .onChange(of: actionEditor) { _, presented in
            if presented { editorWasFull = fullAnalysis }
        }
        .onAppear {
            let continuousEntry = session?.status == .active && session?.hands.last?.handID == handID && hand.map { $0.settlement?.isCurrent(for: $0) != true } == true
            expanded = store.preferences.initialOverview(isContinuousEntry: continuousEntry) == .expanded
            if store.selection.lastHandID == handID { selectedID = store.selection.selectedEventID }
        }
        .alert("尚未保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .fullScreenCover(isPresented: $actionEditor, onDismiss: restoreEditorHeight) {
            if let hand {
                ActionEntryScreen(hand: hand, editing: editingEvent, insertionIndex: insertionIndex, allowIncomplete: incompleteEntry) { event in
                    if let event {
                        let saved = mutate { record in
                            if editingEvent != nil { record.replace(event) }
                            else if let insertionIndex { record.events.insert(event, at: min(insertionIndex, record.events.count)); record.touch() }
                            else { record.append(event) }
                        }
                        guard saved else { return }
                        if insertionIndex == nil { selectedID = event.id }
                        feedback = "已保存 · \(event.kind.title)"
                    }
                    actionEditor = false
                }
            }
        }
        .fullScreenCover(item: $cardTarget, onDismiss: cardEditorDismissed) { target in
            if let hand {
                if target.playerID == nil, let eventID = target.eventID {
                    HandBoardCardEntryFlowView(original: target.originalBoardHand ?? hand, eventID: eventID,
                                               target: target, store: store, onClose: { cardTarget = nil },
                                               onConfirm: { try saveBoardChange($0) },
                                               onSessionCommitted: {
                        undoRecords = []
                        feedback = "更正及后续影响已保存"
                    })
                } else {
                    let existing = target.playerID.flatMap { id in hand.players.first { $0.id == id }?.holeCards } ?? target.eventID.flatMap { id in hand.events.first { $0.id == id }?.cards } ?? []
                    let used = Set(hand.players.filter { $0.id != target.playerID }.flatMap(\.holeCards) + hand.events.filter { $0.id != target.eventID }.flatMap(\.cards))
                    CardEntryScreen(title: target.title, count: target.count, initial: existing, used: used) { cards in
                        if let cards {
                            var insertedEventID: UUID?
                            let saved = mutate { record in
                                if let player = target.playerID, let i = record.players.firstIndex(where: { $0.id == player }) {
                                    record.players[i].holeCards = cards; record.touch()
                                } else if let street = target.street {
                                    let event = HandEvent(street: street, kind: .deal, cards: cards)
                                    record.insertRememberedDeal(event)
                                    insertedEventID = event.id
                                }
                            }
                            guard saved else { return }
                            if let insertedEventID { selectedID = insertedEventID }
                            feedback = "牌张已保存"
                        }
                        cardTarget = nil
                    }
                }
            }
        }
        .sheet(isPresented: $notes) {
            if let hand { HandNotesScreen(hand: hand) { text in mutate { $0.notes = text; $0.updatedAt = Date() }; notes = false } }
        }
        .navigationDestination(isPresented: $navigateHand) {
            if let destinationHandID { HandWorkspaceView(handID: destinationHandID, store: store) }
        }
        .sheet(isPresented: $showSession) {
            NavigationStack {
                if let session { SessionDetailView(sessionID: session.id, store: store) { id in
                    showSession = false
                    if id != handID { destinationHandID = id; navigateHand = true }
                    else { selectedID = store.selection.selectedEventID; detail = selectedID != nil }
                } }
            }
        }
        .sheet(isPresented: $editConfiguration) {
            if let hand { HandSetupView(store: store, editing: hand) { _ in editConfiguration = false } }
        }
        .sheet(isPresented: $showSettlement) {
            if let hand { HandSettlementView(hand: hand, store: store) { settled in
                try store.upsert(settled); feedback = "结算已保存"
            } }
        }
        .sheet(isPresented: $detail) {
            if let hand {
                detailView(hand)
                    .presentationDetents(nodeEditorPresented ? [.fraction(0.73)] : [.fraction(0.73), .large], selection: $detailDetent)
                    .onChange(of: detailDetent) { _, value in
                        if value == .large && !nodeEditorPresented && boardChangePreview == nil && correctionPreview == nil { fullAnalysis = true }
                    }
                    .onChange(of: fullAnalysis) { _, value in
                        if !value { detailDetent = .fraction(0.73) }
                    }
                    .presentationDragIndicator(.visible)
                    .fullScreenCover(isPresented: $fullAnalysis) { detailView(hand, full: true) }
            }
        }
        .sheet(isPresented: correctionPresentation(inDetail: false)) { correctionContent }
        .sheet(item: countsPresentation(inDetail: false)) { counts in HandParticipantCountsView(counts: counts) }

    }

    private func restoreEditorHeight() {
        fullAnalysis = editorWasFull
        if !editorWasFull { detailDetent = .fraction(0.73) }
    }

    private func cardEditorDismissed() {
        guard let context = cardEditorContext else { return }
        #if DEBUG
        if let eventID = context.boardEventID {
            NSLog("M32BoardEntryFlow flow=\(context.flowID) event=\(eventID) revision=\(context.revision ?? -1) phase=cover-closed")
        }
        #endif
        detail = context.host != .workspace
        fullAnalysis = context.host == .analysis
        detailDetent = context.detent
        cardEditorContext = nil
    }

    private func presentCardEditor(_ target: CardTarget) {
        var capturedTarget = target
        if target.playerID == nil, target.eventID != nil {
            capturedTarget.originalBoardHand = hand
        }
        cardEditorContext = CardEditorContext(host: currentPresentationHost, detent: detailDetent,
                                             flowID: target.id, boardEventID: capturedTarget.originalBoardHand == nil ? nil : target.eventID,
                                             revision: capturedTarget.originalBoardHand?.revision)
        cardTarget = capturedTarget
    }

    private var workspaceMenu: some View {
                Menu {
                    Button("牌局笔记", systemImage: "note.text") { notes = true }
                    Button("更正起始信息", systemImage: "slider.horizontal.3") { editConfiguration = true }
                    Button("查看结算", systemImage: "equal.circle") { showSettlement = true }
                    if session != nil { Button("场次与下一手", systemImage: "person.3") { showSession = true } }
                    Button("撤销最近修改", systemImage: "arrow.uturn.backward") { undo() }.disabled(undoRecords.isEmpty)
                    if let hand {
                        Menu("按记忆补录公共牌") {
                            ForEach([HandStreet.flop, .turn, .river], id: \.self) { street in
                                Button(street.label) {
                                    let existing = hand.events.first { $0.kind == .deal && $0.street == street }
                                    presentCardEditor(CardTarget(street: street, title: "补录 \(street.label)", count: street.cardCount, eventID: existing?.id))
                                }
                            }
                        }
                        Button("补录不完整行动") { editingEvent = nil; insertionIndex = nil; incompleteEntry = true; actionEditor = true }
                        let latest = HandReducer.project(hand).latest
                        let legal = HandReducer.legalActions(in: latest, hand: hand)
                        if legal.canCheck { Button("剩余均过牌") { quickActions(foldUntilHero: false) } }
                        if legal.canFold, latest.actorID != hand.players.first(where: \.isHero)?.id { Button("前面均弃牌") { quickActions(foldUntilHero: true) } }
                    }
                } label: { Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44) }.accessibilityLabel("牌局菜单")
    }
    private func workspace(_ hand: HandRecord) -> some View {
        let projection = HandReducer.project(hand)
        let latest = projection.latest
        let readyToSettle = latest.handComplete || (latest.street == .river && latest.roundComplete)
        return ZStack(alignment: .bottom) {
            HandStyle.canvas.ignoresSafeArea()
            VStack(spacing: 10) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("返回上一页")
                    Spacer()
                    Text(hand.title).font(.headline).lineLimit(1)
                    Spacer()
                    workspaceMenu
                }
                summary(hand, snapshot: latest, eventID: hand.events.last?.id, afterNode: true)
                if let settlement = hand.settlement, settlement.isCurrent(for: hand) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(HandStyle.green)
                        Text("已结算 · 投入 \(amount(latest.pot, hand))").font(.caption.weight(.semibold))
                        Spacer()
                        Button("退款与分配") { showSettlement = true }.font(.caption)
                        if session != nil { Button("下一手") { showSession = true }.font(.caption.weight(.semibold)) }
                    }.padding(.horizontal, 8)
                }
                controls(hand)
                timeline(hand, projection: projection)
                if let issue = projection.issues.first {
                    Label(issue.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(HandStyle.red)
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let feedback { Text(feedback).font(.caption).foregroundStyle(HandStyle.green) }
                Spacer(minLength: 4)
                HStack(spacing: 12) {
                    HStack {
                        Button { undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.disabled(undoRecords.isEmpty).accessibilityLabel("撤销")
                        Spacer()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(readyToSettle ? (hand.settlement?.isCurrent(for: hand) == true ? "已结算" : "待结算") : latest.blocked ? "待修正" : latest.roundComplete ? "\(latest.street.next?.label ?? "River") · 发牌" : "\(actorName(hand, latest)) 行动")
                                .font(.subheadline.weight(.semibold))
                            Text("\(hand.events.count) 个记录 · 已自动保存").font(.caption2).foregroundStyle(HandStyle.muted)
                        }
                        Spacer()
                        Button { selectedID = hand.events.last?.id; filterStreet = nil } label: { Image(systemName: "arrow.right.to.line").frame(width: 40, height: 44) }.accessibilityLabel("定位最新")
                    }.padding(.horizontal, 9).background(.white, in: Capsule())
                    Button { continueHand(hand, latest) } label: {
                        Image(systemName: readyToSettle ? "equal" : latest.roundComplete ? "rectangle.on.rectangle" : "plus")
                            .font(.title2.weight(.medium)).frame(width: 58, height: 58).background(HandStyle.ink, in: Circle()).foregroundStyle(.white)
                    }.disabled(latest.blocked).accessibilityLabel(readyToSettle ? "核对结算" : latest.roundComplete ? "录入公共牌" : "添加最新行动")
                }.padding(.bottom, 8)
            }.padding(.horizontal, 12).padding(.top, 4)
        }.foregroundStyle(HandStyle.ink)
    }

    private func summary(_ hand: HandRecord, snapshot: HandSnapshot, eventID: UUID?, afterNode: Bool,
                         analysisSubjectID: UUID? = nil, analysisReveal: Bool = false, isLatest: Bool = true) -> some View {
        let player = isLatest ? hand.players.first(where: \.isHero) : hand.players.first { $0.id == analysisSubjectID }
        let outsContext = HandOutsContext(hand: hand, snapshot: snapshot, subjectID: player?.id,
                                          reveal: analysisReveal, after: afterNode, eventID: eventID)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(snapshot.displayStreet.label.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(HandStyle.muted)
                    HStack(spacing: 4) {
                        knownBoardCards(snapshot)
                    }
                    if snapshot.hasBoardGap { Text("公共牌缺项 · 牌力与计算暂停").font(.caption2).foregroundStyle(HandStyle.gold) }
                    if snapshot.blocked && snapshot.displayStreet != .preflop {
                        Text("下注状态仅核对至\(snapshot.street.title)，已知牌不代表行动完整").font(.caption2).foregroundStyle(HandStyle.muted)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(hand.settlement?.isCurrent(for: hand) == true && !detail ? "终局投入 · 结算前" : "POT").font(.caption2.weight(.semibold)).foregroundStyle(HandStyle.muted)
                    Text(amount(snapshot.pot, hand)).font(.system(size: 29, weight: .semibold, design: .rounded))
                    Text(store.preferences.units == .bigBlinds ? "BB" : "筹码").font(.caption2).foregroundStyle(HandStyle.muted)
                }
            }
            NodePotBreakdown(hand: hand, snapshot: snapshot,
                             eventID: eventID,
                             after: afterNode, units: store.preferences.units)
            if let hero = player {
                HStack(spacing: 8) {
                    Button { presentCardEditor(CardTarget(playerID: hero.id, title: "\(hero.name) · 手牌", count: 2)) } label: {
                        HStack(spacing: 4) {
                            if hero.holeCards.isEmpty { Label("录入手牌", systemImage: "rectangle.on.rectangle") }
                            ForEach(hero.holeCards) { PlayingCard(value: $0.display, small: true) }
                        }
                    }.font(.subheadline)
                    Spacer()
                    participantCountsButton(hand, snapshot: snapshot, eventID: eventID, afterNode: afterNode)
                }
                if !snapshot.blocked, !snapshot.hasBoardGap, hero.holeCards.count == 2, snapshot.board.count >= 3,
                   let value = try? PokerEvaluator.evaluate((hero.holeCards + snapshot.board).map(\.analysisIndex)) {
                    HStack(spacing: 7) {
                        HandRankIcon(category: value.category)
                        Text(value.category.title).font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                }
            }
            if player == nil {
                participantCountsButton(hand, snapshot: snapshot, eventID: eventID, afterNode: afterNode)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HandOutsSummary(context: outsContext, isLatest: isLatest)
        }.handPanel()
    }

    @ViewBuilder private func knownBoardCards(_ snapshot: HandSnapshot) -> some View {
        let streets = HandStreet.allCases.filter { $0.order > 0 && $0.order <= snapshot.displayStreet.order && snapshot.knownBoard[$0] != nil }
        if streets.isEmpty {
            Text("尚未发公共牌").font(.subheadline).foregroundStyle(HandStyle.muted).frame(height: 38)
        } else {
            ForEach(streets, id: \.self) { street in
                Text(street.label).font(.caption2.weight(.semibold)).foregroundStyle(HandStyle.muted)
                ForEach(snapshot.knownBoard[street] ?? []) { PlayingCard(value: $0.display, small: true) }
            }
        }
    }

    private func participantCountsButton(_ hand: HandRecord, snapshot: HandSnapshot, eventID: UUID?, afterNode: Bool) -> some View {
        Button {
            let projection = HandReducer.project(hand)
            let countSnapshot = detail ? snapshot : overviewSnapshot(projection)
            let context: String
            if detail, let eventID, let index = hand.events.filter({ $0.kind != .deal }).firstIndex(where: { $0.id == eventID }) {
                context = "第 \(index + 1) 个行动 · 行动\(afterNode ? "后" : "前")"
            } else if detail { context = "\(snapshot.street.label) · 发牌\(afterNode ? "后" : "前")" }
            else if let street = filterStreet { context = "\(street.label) · 该街最新记录" }
            else { context = "整手 · 最新记录" }
            participantCounts = HandParticipantCounts(hand: hand, snapshot: countSnapshot, session: session, context: context)
        } label: {
            HStack(spacing: 4) {
                Text("发牌 \(hand.players.count) 人 · \(hand.configuration.chipUnit.format(units: hand.configuration.smallBlind))/\(hand.configuration.chipUnit.format(units: hand.configuration.bigBlind))")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.font(.caption).foregroundStyle(HandStyle.muted)
        }.accessibilityLabel("查看五种人数口径")
    }

    private func overviewSnapshot(_ projection: HandProjection) -> HandSnapshot {
        guard let street = filterStreet else { return projection.latest }
        // A street without records has no established end/latest state; never borrow a later street.
        if let node = projection.nodes.last(where: { $0.event.street == street }) { return node.after }
        var unknown = projection.initial
        unknown.street = street
        unknown.blocked = true
        return unknown
    }

    private func controls(_ hand: HandRecord) -> some View {
        HStack {
            Menu {
                Button("全部街次") { filterStreet = nil }
                ForEach(HandStreet.allCases, id: \.self) { street in Button(street.label) { filterStreet = street } }
            } label: { HStack(spacing: 5) { Text(filterStreet?.label ?? "All streets"); Image(systemName: "chevron.down").font(.caption2) } }
            .font(.caption.weight(.semibold))
            if filterPlayer != nil { Button("清除聚焦") { filterPlayer = nil }.font(.caption) }
            Spacer()
            Button {
                expanded.toggle()
                var prefs = store.preferences
                prefs.overviewMode = expanded ? .expanded : .compact
                prefs.overviewModeChosen = true
                do { try store.updatePreferences(prefs) } catch { self.error = error.localizedDescription }
            } label: { Label(expanded ? "Expanded" : "Compact", systemImage: expanded ? "rectangle.split.3x3" : "list.bullet") }.font(.caption)
        }.padding(.horizontal, 4)
    }

    private func timeline(_ hand: HandRecord, projection: HandProjection) -> some View {
        let scopedEvents = hand.events.filter { filterStreet == nil || $0.street == filterStreet }
        let events = scopedEvents.filter { filterPlayer == nil || $0.playerID == filterPlayer || $0.kind == .deal }
        let players = hand.players.sorted { $0.seat < $1.seat }.filter { filterPlayer == nil || $0.id == filterPlayer }
        return ScrollView(.vertical) {
            if let player = hand.players.first(where: { $0.id == filterPlayer }) {
                Text("聚焦 \(player.isHero ? "You · " : "")\(player.name) · \(filterStreet?.label ?? "全部街次") · 已省略其他玩家 \(omittedActionCount(scopedEvents)) 个行动")
                    .font(.caption2).foregroundStyle(HandStyle.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 10)
            }
            if expanded {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        Text(hand.settlement?.isCurrent(for: hand) == true && filterStreet == nil ? "结算后筹码" : "PLAYERS").font(.system(size: 9, weight: .semibold)).foregroundStyle(HandStyle.muted).frame(height: 30)
                        ForEach(players) { player in identity(player, hand: hand, projection: projection).frame(width: 86, height: 64) }
                    }
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: 0) {
                                ForEach(HandStreet.allCases, id: \.self) { street in
                                    let group = events.filter { $0.street == street }
                                    let omitted = omittedActionCount(scopedEvents.filter { $0.street == street })
                                    if !group.isEmpty || omitted > 0 {
                                        VStack(spacing: 0) {
                                            Button {
                                                if let event = group.first(where: { $0.kind != .deal }) { selectedID = event.id }
                                            } label: {
                                                Text(street.label.uppercased() + (omitted > 0 ? " · 省略 \(omitted)" : "")).font(.system(size: 9, weight: .semibold))
                                                    .foregroundStyle(HandStyle.muted).frame(maxWidth: .infinity).frame(height: 22)
                                                    .background(HandStyle.canvas, in: Capsule())
                                            }.padding(.horizontal, 4).frame(height: 30)
                                            HStack(spacing: 0) {
                                                if group.allSatisfy({ $0.kind == .deal }) && omitted > 0 {
                                                    Text("无该玩家行动").font(.caption2).foregroundStyle(HandStyle.muted)
                                                        .frame(width: 92, height: 64)
                                                }
                                                ForEach(group) { event in
                                                    VStack(spacing: 0) {
                                                        ForEach(players) { player in
                                                            ZStack {
                                                                Rectangle().fill(HandStyle.line.opacity(0.4)).frame(height: 1)
                                                                if event.playerID == player.id { eventButton(event, hand: hand) }
                                                                else if event.kind == .deal, player.id == players.first?.id {
                                                                    Text(event.cards.map(\.display).joined(separator: " ")).font(.caption2)
                                                                }
                                                            }.frame(width: event.kind == .deal ? 48 : 62, height: 64)
                                                        }
                                                    }.id(event.id)
                                                }
                                            }
                                        }
                                    }
                                }
                                if scopedEvents.isEmpty { Text("此街次尚无记录").font(.caption).foregroundStyle(HandStyle.muted).padding() }
                            }
                        }.onChange(of: selectedID) { _, id in if let id { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .trailing) } } }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    if hand.settlement?.isCurrent(for: hand) == true && filterStreet == nil { Text("结算后筹码").font(.caption2).foregroundStyle(HandStyle.muted) }
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) { ForEach(players) { identity($0, hand: hand, projection: projection).frame(width: 54) } }
                    }
                    ForEach(HandStreet.allCases, id: \.self) { street in
                        let streetEvents = events.filter { $0.street == street }
                        let omitted = omittedActionCount(scopedEvents.filter { $0.street == street })
                        if !streetEvents.isEmpty || omitted > 0 {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(street.label.uppercased() + (omitted > 0 ? " · 已省略其他玩家 \(omitted) 个行动" : "")).font(.caption2.weight(.semibold)).foregroundStyle(HandStyle.muted)
                                if streetEvents.allSatisfy({ $0.kind == .deal }) && omitted > 0 {
                                    Text("该玩家本街无行动 · 全桌行动保留在完整牌局中").font(.caption2).foregroundStyle(HandStyle.muted)
                                }
                                ScrollView(.horizontal) {
                                    HStack(spacing: 10) {
                                        ForEach(streetEvents) { event in
                                            VStack(spacing: 6) {
                                                if let player = hand.players.first(where: { $0.id == event.playerID }) { HandPortrait(seat: player.seat, hero: player.isHero, size: 27) }
                                                else { Image(systemName: "rectangle.on.rectangle").frame(height: 27) }
                                                eventButton(event, hand: hand)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if scopedEvents.isEmpty { Text("此街次尚无记录").font(.caption).foregroundStyle(HandStyle.muted) }
                }.padding(14)
            }
        }.background(.white, in: RoundedRectangle(cornerRadius: 22))
    }

    private func omittedActionCount(_ events: [HandEvent]) -> Int {
        guard let filterPlayer else { return 0 }
        return events.filter { $0.kind != .deal && $0.playerID != nil && $0.playerID != filterPlayer }.count
    }

    private func identity(_ player: HandPlayer, hand: HandRecord, projection: HandProjection) -> some View {
        let snap = overviewSnapshot(projection)
        let missingStreetSnapshot = filterStreet.map { street in !projection.nodes.contains { $0.event.street == street } } ?? false
        let state = missingStreetSnapshot ? nil : snap.player(player.id)
        let balance = missingStreetSnapshot ? ChipAmount.unknown : filterStreet == nil && hand.settlement?.isCurrent(for: hand) == true
            ? hand.settlement?.finalBalances.first(where: { $0.playerID == player.id })?.amount ?? state?.remaining ?? .unknown
            : state?.remaining ?? .unknown
        let balanceLabel = missingStreetSnapshot ? "待核对" : amount(balance, hand)
        return Button { filterPlayer = filterPlayer == player.id ? nil : player.id } label: {
            Group {
                if expanded {
                    HStack(spacing: 5) {
                        VStack(spacing: 2) {
                            identityPortrait(player, state: state, unknown: missingStreetSnapshot, size: 29)
                            Text(player.isHero ? "You" : player.name).font(.system(size: 9)).lineLimit(1)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(position(player, hand)).font(.system(size: 10, weight: .semibold))
                            Text(balanceLabel).font(.system(size: 13, weight: .medium, design: .rounded))
                        }
                    }
                } else {
                    VStack(spacing: 3) {
                        identityPortrait(player, state: state, unknown: missingStreetSnapshot, size: 34)
                        Text(player.isHero ? "You" : player.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        Text(position(player, hand)).font(.system(size: 9)).foregroundStyle(HandStyle.muted)
                        Text(balanceLabel).font(.system(size: 11, design: .monospaced)).foregroundStyle(HandStyle.muted)
                    }
                }
            }.frame(maxWidth: .infinity).background(filterPlayer == player.id ? HandStyle.line.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func identityPortrait(_ player: HandPlayer, state: PlayerSnapshot?, unknown: Bool, size: CGFloat) -> some View {
        if unknown {
            // No state ring: a missing street cannot establish active, folded or all-in status.
            Image("Portrait\((max(0, player.seat) % 9) + 1)")
                .resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "questionmark.circle.fill").font(.system(size: 13))
                        .foregroundStyle(HandStyle.muted).background(.white, in: Circle())
                }.accessibilityHidden(true)
        } else {
            HandPortrait(seat: player.seat, hero: player.isHero, folded: state?.folded == true, allIn: state?.allIn == true, size: size)
        }
    }

    private func eventButton(_ event: HandEvent, hand: HandRecord) -> some View {
        Button {
            selectResearchNode(event.id, hand: hand); subject = event.playerID ?? hand.players.first(where: \.isHero)?.id; after = false; fullAnalysis = false; detail = true
            do { try store.updateSelection(StoreSelection(lastHandID: handID, selectedEventID: event.id)) } catch { self.error = error.localizedDescription }
        } label: {
            VStack(spacing: 3) {
                Text("\((hand.events.filter { $0.kind != .deal }.firstIndex { $0.id == event.id }).map { String($0 + 1) } ?? "")")
                    .font(.system(size: 9)).foregroundStyle(HandStyle.muted)
                ZStack {
                    if let value = event.amount {
                        Circle().fill(HandStyle.color(event.kind)).frame(width: 34, height: 34)
                        Text(amount(value, hand)).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                            .minimumScaleFactor(0.6).lineLimit(1).frame(width: 30)
                    } else if event.kind == .fold {
                        Circle().fill(HandStyle.muted.opacity(0.6)).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: event.kind == .check ? "checkmark" : "rectangle.on.rectangle").font(.caption)
                    }
                }.frame(height: 34)
                Text(event.kind.label).font(.system(size: 8, weight: .medium)).lineLimit(1).foregroundStyle(HandStyle.color(event.kind))
            }.frame(width: 54, height: 62)
                .background(selectedID == event.id ? HandStyle.canvas : .clear, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedID == event.id ? HandStyle.ink : .clear))
        }.buttonStyle(.plain).accessibilityLabel("\(event.kind.title) \(event.amount.map { amount($0, hand) } ?? "")")
    }

    private func rangeWorkspaceState(eventID: UUID, subjectID: UUID) -> Binding<HandRangeWorkspaceState> {
        let identity = HandRangeWorkspaceIdentity(handID: handID, eventID: eventID, subjectID: subjectID,
                                                  after: after, reveal: reveal)
        return Binding(get: { rangeWorkspaceStates[identity] ?? HandRangeWorkspaceState() },
                       set: { rangeWorkspaceStates[identity] = $0 })
    }

    private func resetResearchBaseline(_ hand: HandRecord) {
        let eventID = hand.events.first(where: { $0.id == selectedID })?.id ?? hand.events.last?.id
        researchBaseline = eventID.map { ResearchNodeBaseline(eventID: $0, revision: hand.revision, eventIDs: Set(hand.events.map(\.id))) }
    }

    private func selectResearchNode(_ eventID: UUID, hand: HandRecord) {
        selectedID = eventID
        // Even tapping the already selected node explicitly adopts the latest input version.
        resetResearchBaseline(hand)
    }

    private func researchChangeMessage(_ hand: HandRecord, eventID: UUID?) -> String? {
        guard let baseline = researchBaseline, baseline.eventID == eventID,
              baseline.revision != hand.revision,
              let index = hand.events.firstIndex(where: { $0.id == baseline.eventID }) else { return nil }
        let hasNewLaterRecord = hand.events.dropFirst(index + 1).contains { !baseline.eventIDs.contains($0.id) }
        return hasNewLaterRecord
            ? "牌局已推进 · 新增后续记录；仍在研究原节点，旧计算已失效。"
            : "牌局事实已修改 · 仍在研究原节点，旧计算已失效；请核对当前条件。"
    }

    private func detailView(_ hand: HandRecord, full: Bool = false) -> some View {
        let projection = HandReducer.project(hand)
        let node = projection.nodes.first { $0.id == selectedID } ?? projection.nodes.last
        let snapshot = (after ? node?.after : node?.before) ?? projection.latest
        let player = hand.players.first { $0.id == subject } ?? hand.players.first!
        let ps = snapshot.player(player.id)
        return NavigationStack {
            ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Color.clear.frame(height: 1).id("detail-top")
                    if full {
                        HStack(spacing: 6) {
                            Text(snapshot.displayStreet.label).font(.caption.weight(.semibold))
                            knownBoardCards(snapshot)
                            Spacer()
                            Text("Pot \(amount(snapshot.pot, hand))").font(.headline)
                            Button { presentCardEditor(CardTarget(playerID: player.id, title: "\(player.name) · 手牌", count: 2)) } label: { Image(systemName: "rectangle.on.rectangle").frame(width: 36, height: 36) }.accessibilityLabel("分析对象手牌")
                        }
                        NodePotBreakdown(hand: hand, snapshot: snapshot, eventID: node?.id, after: after, units: store.preferences.units)
                        participantCountsButton(hand, snapshot: snapshot, eventID: node?.id, afterNode: after)
                    } else { summary(hand, snapshot: snapshot, eventID: node?.id, afterNode: after,
                                     analysisSubjectID: player.id, analysisReveal: reveal, isLatest: false) }
                    replayControls(projection, currentID: node?.id, hand: hand)
                    if let message = researchChangeMessage(hand, eventID: node?.id) {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(HandStyle.gold)
                            .accessibilityIdentifier("research-input-change")
                    }
                    ScrollViewReader { timelineReader in
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(projection.nodes.filter { $0.event.street == node?.event.street }) { n in
                                    Button { selectResearchNode(n.id, hand: hand); subject = n.event.playerID ?? subject } label: {
                                        Text(n.event.kind.label).font(.caption.weight(.semibold)).padding(9).background(n.id == node?.id ? HandStyle.line : .white, in: Capsule())
                                    }.id(n.id)
                                    .accessibilityLabel(detailNodeLabel(n.event, hand: hand))
                                    .accessibilityAddTraits(n.id == node?.id ? .isSelected : [])
                                }
                            }
                        }
                        .onAppear { if let id = node?.id { timelineReader.scrollTo(id, anchor: .center) } }
                        .onChange(of: selectedID) { _, id in if let id { timelineReader.scrollTo(id, anchor: .center) } }
                    }
                    HStack(spacing: 0) {
                        Button { after = false } label: { Text("Before · 行动前").frame(maxWidth: .infinity).padding(10).background(after ? .clear : .white, in: Capsule()) }.accessibilityAddTraits(after ? [] : .isSelected)
                        Button { after = true } label: { Text("After · 行动后").frame(maxWidth: .infinity).padding(10).background(after ? .white : .clear, in: Capsule()) }.accessibilityAddTraits(after ? .isSelected : [])
                    }.font(.caption.weight(.semibold)).padding(3).background(HandStyle.line, in: Capsule())
                    HStack {
                        Picker("分析对象", selection: $subject) { ForEach(hand.players) { Text($0.name).tag(Optional($0.id)) } }
                        Spacer()
                        Picker("视角", selection: $reveal) { Text("决策").tag(false); Text("揭牌").tag(true) }.pickerStyle(.segmented).frame(width: 140)
                    }
                    if !full {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text(player.name).font(.title2.weight(.semibold)); Spacer(); Text(node?.event.kind.label ?? "START").foregroundStyle(HandStyle.color(node?.event.kind ?? .check)) }
                        HStack {
                            metric("后手", amount(ps?.remaining ?? .unknown, hand))
                            Spacer()
                            metric(snapshot.displayStreet != snapshot.street ? "已核对\(snapshot.street.title)投入" : "本街投入", amount(ps?.streetContribution ?? .unknown, hand))
                            Spacer()
                            metric(snapshot.displayStreet != snapshot.street ? "\(snapshot.street.title)待跟注" : "待跟注", ps?.streetContribution.units.map { amount(.init(units: max(0, snapshot.currentBet - $0)), hand) } ?? "未知")
                        }
                        Button {
                            presentCardEditor(CardTarget(playerID: player.id, title: "\(player.name) · 手牌", count: 2))
                        } label: { HStack { ForEach(player.holeCards) { PlayingCard(value: $0.display) }; Label(player.holeCards.isEmpty ? "录入手牌" : "修改手牌", systemImage: "pencil") } }
                    }.handPanel()
                    }
                    if let issue = node?.issues.first { Label(issue.message, systemImage: "exclamationmark.triangle").foregroundStyle(HandStyle.red) }
                    if full, let event = node?.event {
                        HandRangeWorkspace(hand: hand, eventID: event.id, snapshot: snapshot, subjectID: player.id, after: after, reveal: reveal, store: store, transientPlans: $transientPlans, state: rangeWorkspaceState(eventID: event.id, subjectID: player.id)).handPanel().id("detail-range")
                        Color.clear.frame(height: 1).id("detail-analysis")
                        if !store.preferences.hideAnalysis || analysisRevealed {
                            HandAnalysisSection(hand: hand, snapshot: snapshot, subjectID: player.id, reveal: reveal, eventID: event.id, after: after, store: store, transientPlans: transientPlans)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("先留下自己的判断").font(.headline)
                                Button("记录节点判断") { annotationEvent = event }
                                Button("查看本地分析") { analysisRevealed = true }
                            }.handPanel()
                        }
                    } else {
                        Button { fullAnalysis = true } label: {
                            HStack { Label("范围与本地分析", systemImage: "square.grid.3x3"); Spacer(); Image(systemName: "arrow.up") }.font(.subheadline.weight(.semibold)).handPanel()
                        }
                    }
                    Color.clear.frame(height: 1).id("detail-actions")
                    if let event = node?.event {
                        Button("节点笔记与书签", systemImage: "bookmark") { annotationEvent = event }
                        Button("记忆底池与推导核对", systemImage: "equal.circle") { rememberedPotEditor = true }
                        Menu("在此节点补录") {
                            Button("在此前插入行动") { beginInsertion(event, hand: hand, after: false) }
                            Button("在此后插入行动") { beginInsertion(event, hand: hand, after: true) }
                        }
                        if event.kind == .deal {
                            Button("更正公共牌", systemImage: "pencil") { presentCardEditor(CardTarget(street: event.street, title: "更正 \(event.street.label)", count: event.street.cardCount, eventID: event.id)) }
                            if hand.dealIsOutOfOrder(eventID: event.id) {
                                Button("按街次重插此公共牌", systemImage: "arrow.up.arrow.down") {
                                    mutate { $0.repositionDeal(eventID: event.id) }
                                }
                            }
                            Button("删除公共牌 · 保留后续记录", systemImage: "trash", role: .destructive) { removeEvent(event.id) }
                        }
                    }
                    if let event = node?.event, (!event.kind.isForced || [.liveBlind, .deadBlind].contains(event.kind)) && event.kind != .deal {
                        Button("编辑此行动", systemImage: "square.and.pencil") { editingEvent = event; insertionIndex = nil; incompleteEntry = false; actionEditor = true }
                        Button("删除此行动 · 保留后续记录", systemImage: "trash", role: .destructive) { removeEvent(event.id) }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("node-details-scroll").id(full)
                .accessibilityScrollAction { edge in
                    let anchors = full ? ["detail-top", "detail-range", "range-details", "detail-analysis", "detail-actions"] : ["detail-top", "detail-actions"]
                    detailScrollPage = min(anchors.count - 1, max(0, detailScrollPage + (edge == .top ? -1 : 1)))
                    reader.scrollTo(anchors[detailScrollPage], anchor: .top)
                }
                .background(HandStyle.canvas)
                .navigationTitle("\(node?.event.street.label ?? "Hand") · 节点详情").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if full {
                        ToolbarItem(placement: .topBarLeading) {
                            Menu("定位") {
                                Button("范围矩阵") { reader.scrollTo("detail-range", anchor: .top) }
                                Button("组合与方案") { reader.scrollTo("range-details", anchor: .top) }
                                Button("我的牌力与分析") { reader.scrollTo("detail-analysis", anchor: .top) }
                                Button("笔记与编辑") { reader.scrollTo("detail-actions", anchor: .top) }
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button(full ? "返回详情" : "完成") { if full { fullAnalysis = false } else { detail = false } } }
                }
            }
        }.sheet(isPresented: Binding(get: { annotationEvent != nil && fullAnalysis == full }, set: { if !$0 && fullAnalysis == full { annotationEvent = nil } })) {
            if let event = annotationEvent {
                ReviewNodeEditor(handID: handID, eventID: event.id, store: store,
                                 captureContext: ReviewCaptureContext(subjectID: player.id, after: after, reveal: reveal,
                                                                      scope: .decision, transientPlans: transientPlans))
            }
        }.sheet(isPresented: correctionPresentation(inDetail: true, fullContext: full)) { correctionContent }
        .sheet(item: countsPresentation(inDetail: true, fullContext: full)) { counts in HandParticipantCountsView(counts: counts) }
        .sheet(isPresented: Binding(get: { rememberedPotEditor && fullAnalysis == full }, set: { if fullAnalysis == full { rememberedPotEditor = $0 } })) {
            RememberedPotScreen(hand: hand, nodeEventID: node?.id, after: after) { updated in
                try store.upsert(updated)
            }
        }
    }

    private func countsPresentation(inDetail: Bool, fullContext: Bool? = nil) -> Binding<HandParticipantCounts?> {
        Binding(get: {
            detail == inDetail && (fullContext == nil || fullAnalysis == fullContext) ? participantCounts : nil
        }, set: { value in
            if detail == inDetail && (fullContext == nil || fullAnalysis == fullContext) { participantCounts = value }
        })
    }

    private func detailNodeLabel(_ event: HandEvent, hand: HandRecord) -> String {
        let number = (hand.events.firstIndex { $0.id == event.id } ?? 0) + 1
        let player = hand.players.first { $0.id == event.playerID }?.name ?? "全桌"
        return "第\(number)步 · \(player) · \(event.kind.title)" + (event.amount.map { " \(amount($0, hand))" } ?? "")
    }

    private func replayControls(_ projection: HandProjection, currentID: UUID?, hand: HandRecord) -> some View {
        let index = projection.nodes.firstIndex { $0.id == currentID } ?? 0
        return HStack(spacing: 8) {
            Button {
                let node = projection.nodes[index - 1]
                selectResearchNode(node.id, hand: hand); subject = node.event.playerID ?? subject
            } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
            .disabled(index == 0).accessibilityLabel("上一步")
            VStack(spacing: 2) {
                Text("\(projection.nodes.isEmpty ? 0 : index + 1) / \(projection.nodes.count) · \(projection.nodes.isEmpty ? "" : projection.nodes[index].event.street.label)")
                    .font(.caption).foregroundStyle(HandStyle.muted)
                if !projection.nodes.isEmpty {
                    Text(detailNodeLabel(projection.nodes[index].event, hand: hand)).font(.caption.weight(.semibold)).lineLimit(2)
                }
            }.frame(maxWidth: .infinity)
            Button {
                let node = projection.nodes[index + 1]
                selectResearchNode(node.id, hand: hand); subject = node.event.playerID ?? subject
            } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
            .disabled(index + 1 >= projection.nodes.count).accessibilityLabel("下一步")
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(name).font(.caption).foregroundStyle(HandStyle.muted); Text(value).font(.title3.weight(.semibold)) }
    }
    private func amount(_ value: ChipAmount, _ hand: HandRecord) -> String {
        guard store.preferences.units == .bigBlinds, let units = value.units, hand.configuration.bigBlind > 0 else { return hand.configuration.chipUnit.format(value) }
        return (value.certainty == .approximate ? "≈" : "") + String(format: "%.2f", Double(units) / Double(hand.configuration.bigBlind))
    }
    private func position(_ player: HandPlayer, _ hand: HandRecord) -> String {
        HandReducer.positions(in: hand)[player.id] ?? "S\(player.seat + 1)"
    }
    private func actorName(_ hand: HandRecord, _ snapshot: HandSnapshot) -> String { hand.players.first { $0.id == snapshot.actorID }?.name ?? "—" }
    private func continueHand(_ hand: HandRecord, _ snapshot: HandSnapshot) {
        if snapshot.handComplete || (snapshot.street == .river && snapshot.roundComplete) { showSettlement = true }
        else if snapshot.roundComplete, let street = snapshot.street.next { presentCardEditor(CardTarget(street: street, title: "\(street.label) · 公共牌", count: street.cardCount)) }
        else { editingEvent = nil; insertionIndex = nil; incompleteEntry = false; actionEditor = true }
    }
    private func quickActions(foldUntilHero: Bool) {
        mutate { record in
            for _ in 0..<record.players.count {
                let latest = HandReducer.project(record).latest
                let legal = HandReducer.legalActions(in: latest, hand: record)
                guard let actor = legal.actorID else { break }
                if foldUntilHero {
                    if actor == record.players.first(where: \.isHero)?.id || !legal.canFold { break }
                    record.append(HandEvent(street: latest.street, playerID: actor, kind: .fold, source: "用户触发前面均弃牌"))
                } else {
                    guard legal.canCheck else { break }
                    record.append(HandEvent(street: latest.street, playerID: actor, kind: .check, source: "用户触发剩余均过牌"))
                }
            }
        }
        feedback = "快捷行动已保存 · 可撤销整组"
    }
    private func beginInsertion(_ event: HandEvent, hand: HandRecord, after: Bool) {
        guard let index = hand.events.firstIndex(where: { $0.id == event.id }) else { return }
        editingEvent = nil; insertionIndex = index + (after ? 1 : 0); incompleteEntry = true; actionEditor = true
    }
    private func removeEvent(_ eventID: UUID) {
        if let hand, let event = hand.events.first(where: { $0.id == eventID }), event.kind == .deal {
            presentBoardChange(HandBoardChangePreview(original: hand, event: event,
                                                     revisionHighWatermark: store.preparingFactEdit(hand).allocatedRevisionCeiling))
            return
        }
        if mutate({ $0.remove(eventID: eventID) }) { closeRemovedSelectedNode() }
    }
    private func presentBoardChange(_ preview: HandBoardChangePreview) {
        boardChangePreview = preview
        if let linked = store.sessionRequiringCorrection(for: preview.proposed) {
            correctionPreview = store.previewSessionCorrection(linked, request: .hand(replacement: preview.proposed))
        } else {
            correctionPreview = nil
        }
    }
    private func saveBoardChange(_ preview: HandBoardChangePreview) throws {
        guard let hand, try preview.isCurrent(for: hand), store.sessionRequiringCorrection(for: preview.proposed) == nil else {
            throw LocalStoreError.invalid("原记录或场次已变化，请取消后重新预览\(preview.operationTitle)影响。")
        }
        try store.upsert(preview.proposed)
        undoRecords.append(HandUndoRecord(previous: preview.original, saved: self.hand ?? preview.proposed))
        feedback = "公共牌已\(preview.operationTitle) · 后续记录保留 · 可撤销"
    }
    private func commitBoardChange(_ preview: HandBoardChangePreview) throws {
        try saveBoardChange(preview)
        boardChangePreview = nil
        if preview.isDeletion { closeRemovedSelectedNode() }
    }
    private func closeRemovedSelectedNode() {
        guard let selectedID, hand?.events.contains(where: { $0.id == selectedID }) == false else { return }
        self.selectedID = nil
        fullAnalysis = false
        detail = false
    }
    @discardableResult private func mutate(_ change: (inout HandRecord) -> Void) -> Bool {
        guard var record = hand else { return false }
        let prior = record
        record = store.preparingFactEdit(record)
        change(&record)
        if let linked = store.sessionRequiringCorrection(for: record) {
            boardChangePreview = nil
            correctionPreview = store.previewSessionCorrection(linked, request: .hand(replacement: record))
            actionEditor = false; cardTarget = nil
            return false
        }
        do { try store.upsert(record); undoRecords.append(HandUndoRecord(previous: prior, saved: hand ?? record)); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    private func correctionPresentation(inDetail: Bool, fullContext: Bool? = nil) -> Binding<Bool> {
        return Binding(get: {
            (correctionPreview != nil || boardChangePreview != nil) && detail == inDetail && (fullContext == nil || fullContext == fullAnalysis) && !nodeEditorPresented
        }, set: { presented in
            guard !presented, detail == inDetail, (fullContext == nil || fullContext == fullAnalysis), !nodeEditorPresented else { return }
            correctionPreview = nil
            boardChangePreview = nil
        })
    }
    @ViewBuilder private var correctionContent: some View {
        if let preview = correctionPreview {
            SessionCorrectionView(preview: preview, store: store, boardChangePreview: boardChangePreview) {
                correctionPreview = nil; boardChangePreview = nil; undoRecords = []; feedback = "更正及后续影响已保存"
                closeRemovedSelectedNode()
            }
        } else if let preview = boardChangePreview {
            HandBoardChangePreviewView(preview: preview) { try commitBoardChange(preview) }
        }
    }
    private func undo() {
        guard let operation = undoRecords.last, let current = hand else { return }
        do {
            guard try operation.matches(current) else {
                throw LocalStoreError.invalid("记录已在其他入口保存，不能用旧撤销覆盖新的笔记、配置或结算。")
            }
            var restored = store.preparingFactEdit(operation.previous)
            restored.updatedAt = Date()
            try store.restoreUndo(restored, replacing: current)
            undoRecords.removeLast()
            feedback = "已撤销"
        } catch { self.error = error.localizedDescription }
    }
}

private enum PresentationHost: Hashable {
    case workspace, detail, analysis
}

private struct HandUndoRecord {
    let previous: HandRecord
    let saved: HandRecord

    func matches(_ current: HandRecord) throws -> Bool {
        try Self.baseline(saved) == Self.baseline(current)
    }
    private static func baseline(_ hand: HandRecord) throws -> Data {
        var comparable = hand
        // Storage time and allocation metadata change during our own preceding undo;
        // every user-visible value and fact identity remains part of the guard.
        comparable.updatedAt = .distantPast
        comparable.revisionHighWatermark = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(comparable)
    }
}

private struct CardEditorContext {
    let host: PresentationHost
    let detent: PresentationDetent
    let flowID: UUID
    let boardEventID: UUID?
    let revision: Int?
}

struct CardTarget: Identifiable {
    var id = UUID()
    var playerID: UUID? = nil
    var street: HandStreet? = nil
    var title: String
    var count: Int
    var eventID: UUID? = nil
    var originalBoardHand: HandRecord? = nil
}

/// Selection and impact confirmation share one cover and one stable CardTarget identity.
private struct HandBoardCardEntryFlowView: View {
    let original: HandRecord
    let eventID: UUID
    let target: CardTarget
    @ObservedObject var store: LocalStore
    let onClose: () -> Void
    let onConfirm: (HandBoardChangePreview) throws -> Void
    let onSessionCommitted: () -> Void
    @State private var phase: Phase = .selection
    @State private var saved = false

    private enum Phase {
        case selection
        case hand(HandBoardChangePreview)
        case session(HandBoardChangePreview, SessionCorrectionPreview)
    }

    var body: some View {
        switch phase {
        case .selection:
            if let event = original.events.first(where: { $0.id == eventID && $0.kind == .deal }) {
                let used = Set(original.players.flatMap(\.holeCards) + original.events.filter { $0.id != eventID }.flatMap(\.cards))
                CardEntryScreen(title: target.title, count: target.count, initial: event.cards, used: used) { cards in
                    finishSelection(cards, event: event)
                }.onAppear { trace("opened") }
            } else {
                VStack(spacing: 16) {
                    ContentUnavailableView("原公共牌记录不可用", systemImage: "rectangle.stack")
                    Button("返回原节点") { close() }
                }
            }
        case .hand(let preview):
            HandBoardChangePreviewView(preview: preview, onClose: close) {
                trace("ordinary-commit-start")
                do {
                    try onConfirm(preview)
                    saved = true
                    trace("ordinary-commit-success")
                } catch {
                    trace("ordinary-commit-failure")
                    throw error
                }
            }.onAppear { trace("ordinary-preview-visible") }
        case .session(let board, let session):
            SessionCorrectionView(preview: session, store: store, boardChangePreview: board, onClose: close,
                                  onCommitTrace: { trace("session-commit-" + $0) }) {
                saved = true
                onSessionCommitted()
            }.onAppear { trace("session-preview-visible") }
        }
    }

    private func finishSelection(_ cards: [PokerCard]?, event: HandEvent) {
        guard let cards else { close(); return }
        // Public-card selection order does not change its facts.
        guard Set(cards) != Set(event.cards) else {
            trace("no-change")
            onClose()
            return
        }
        var changedEvent = event
        changedEvent.cards = cards
        var proposed = store.preparingFactEdit(original)
        proposed.replace(changedEvent)
        let preview = HandBoardChangePreview(original: original, event: event, proposed: proposed)
        trace("changed")
        if let linked = store.sessionRequiringCorrection(for: proposed) {
            let session = store.previewSessionCorrection(linked, request: .hand(replacement: proposed))
            phase = .session(preview, session)
            trace("session-preview-set")
        } else {
            phase = .hand(preview)
            trace("ordinary-preview-set")
        }
    }

    private func close() {
        trace(saved ? "end-saved" : "cancel")
        onClose()
    }

    private func trace(_ stage: String) {
        #if DEBUG
        NSLog("M32BoardEntryFlow flow=\(target.id) event=\(eventID) revision=\(original.revision) phase=\(stage)")
        #endif
    }
}

private struct HandNotesScreen: View {
    let hand: HandRecord
    let save: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            TextEditor(text: $text).padding().scrollContentBackground(.hidden).background(HandStyle.canvas)
                .navigationTitle("牌局笔记")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { save(text) } } }
                .onAppear { text = hand.notes }
        }
    }
}
