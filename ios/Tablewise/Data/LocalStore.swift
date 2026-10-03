import Foundation
import Combine

struct StoreSelection: Codable, Equatable {
    var lastHandID: UUID?
    var selectedEventID: UUID?
    var lastSessionID: UUID?
}

struct StorePreferences: Codable, Equatable {
    enum Units: String, Codable, CaseIterable { case chips, bigBlinds }
    enum OverviewMode: String, Codable, CaseIterable { case compact, expanded }
    var units: Units = .chips
    var overviewMode: OverviewMode = .compact
    // New installations use journey defaults until an explicit choice. Legacy
    // backups omit this field; preserve their stored mode as a prior choice.
    var overviewModeChosen: Bool? = false
    func initialOverview(isContinuousEntry: Bool) -> OverviewMode {
        overviewModeChosen == false ? (isContinuousEntry ? .expanded : .compact) : overviewMode
    }
    var hideAnalysis: Bool = false
}

struct NodeAnnotation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var handID: UUID
    var eventID: UUID
    var text: String = ""
    var isBookmarked: Bool = false
    var reviewStatus: String? = nil
    var question: String? = nil
    var judgment: String? = nil
    var reflection: String? = nil
    var rangePlanIDs: [UUID]? = nil
    var rangePlanSnapshots: [RangePlan]? = nil
    var rangeCapture: ReviewRangeCapture? = nil
    var completedAt: Date? = nil
    /// Preserves the original node when its event is removed; never reattaches to a neighbor.
    var removedEvent: HandEvent? = nil
    var isMissingEvent: Bool { removedEvent != nil }
}

fileprivate struct StoreDocument: Codable {
    var schemaVersion: Int = 1
    var hands: [HandRecord] = []
    var selection = StoreSelection()
    var preferences = StorePreferences()
    var nodeAnnotations: [NodeAnnotation] = []
    // Optional field keeps existing v1 backups readable.
    var rangePlans: [RangePlan]? = nil
    var sessions: [SessionRecord]? = nil
}

struct ImportPreview {
    fileprivate let document: StoreDocument
    var handCount: Int { document.hands.count }
    var annotationCount: Int { document.nodeAnnotations.count }
    var rangePlanCount: Int { document.rangePlans?.count ?? 0 }
    var sessionCount: Int { document.sessions?.count ?? 0 }
    var handTitles: [String] { document.hands.map(\.title) }
}

enum LocalStoreError: LocalizedError {
    case invalid(String)
    case recoveryRequired
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .recoveryRequired: return "本地文件无法读取。原文件已保留，请先导出原文件或明确选择恢复备份／重建本地数据。"
        }
    }
}

/// A successful mutation means the entire versioned document has been atomically written.
/// A damaged source is never replaced by an implicit empty document.
@MainActor
final class LocalStore: ObservableObject {
    @Published private(set) var hands: [HandRecord] = []
    @Published private(set) var selection = StoreSelection()
    @Published private(set) var preferences = StorePreferences()
    @Published private(set) var nodeAnnotations: [NodeAnnotation] = []
    @Published private(set) var rangePlans: [RangePlan] = []
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var saveError: String?
    @Published private(set) var requiresRecovery = false

    private let fileURL: URL
    private var document = StoreDocument()
    private static let maximumImportBytes = 32 * 1_024 * 1_024

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tablewise", isDirectory: true)
        fileURL = base.appendingPathComponent("tablewise-store-v1.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let loaded = try Self.decode(Data(contentsOf: fileURL))
            try Self.validate(loaded)
            publish(loaded)
        } catch {
            requiresRecovery = true
            saveError = "本地数据读取失败，原文件已保留：\(error.localizedDescription)"
        }
    }

    func upsert(_ hand: HandRecord) throws {
        do { try commit(upserting(hand, into: document)) }
        catch { saveError = "保存失败：\(error.localizedDescription)"; throw error }
    }

    /// Restoration is distinct from creating a new fact identity. The workspace
    /// first checks its saved operation baseline; recheck the exact live record here.
    func restoreUndo(_ hand: HandRecord, replacing expected: HandRecord) throws {
        do {
            guard let current = document.hands.first(where: { $0.id == hand.id }),
                  try Self.encodedValue(current) == Self.encodedValue(expected) else {
                throw LocalStoreError.invalid("记录已改变，不能覆盖新的保存；请重新核对。")
            }
            try commit(upserting(hand, into: document, restoringFactIdentity: true))
        } catch { saveError = "撤销失败：\(error.localizedDescription)"; throw error }
    }

    /// Lazy preparation affects only the detached target, never the stored original.
    /// Call before touch/preview so settlement and analysis identities use the final number.
    func preparingFactEdit(_ hand: HandRecord) -> HandRecord {
        var prepared = hand
        prepared.retainRevisionCeiling(Self.revisionCeiling(for: hand.id, in: document))
        return prepared
    }

    func previewSessionCorrection(_ session: SessionRecord, hands originals: [HandRecord]? = nil,
                                  request: SessionCorrectionRequest) -> SessionCorrectionPreview {
        var ceilings: [UUID: Int] = [:]
        for ref in session.hands { ceilings[ref.handID] = Self.revisionCeiling(for: ref.handID, in: document) }
        return SessionReducer.previewCorrection(session, hands: originals ?? document.hands, request: request, revisionHighWatermarks: ceilings)
    }

    func sessionRequiringCorrection(for hand: HandRecord) -> SessionRecord? {
        guard let previous = document.hands.first(where: { $0.id == hand.id }), Self.affectsSessionBalances(previous, hand) else { return nil }
        return sessions.first { session in
            session.hands.contains { $0.handID == hand.id && $0.number < session.hands.count }
        }
    }

    private static func affectsSessionBalances(_ previous: HandRecord, _ replacement: HandRecord) -> Bool {
        affectsRecordedFacts(previous, replacement) || previous.revision != replacement.revision
        || (try? encodedValue(previous.settlement)) != (try? encodedValue(replacement.settlement))
    }

    private static func affectsRecordedFacts(_ previous: HandRecord, _ replacement: HandRecord) -> Bool {
        previous.configuration != replacement.configuration || previous.gameFormat != replacement.gameFormat || previous.players != replacement.players
        || previous.events != replacement.events
        || (try? encodedValue(previous.ruleContext)) != (try? encodedValue(replacement.ruleContext))
    }

    private func upserting(_ incoming: HandRecord, into current: StoreDocument, applyingCorrection: Bool = false,
                           restoringFactIdentity: Bool = false) throws -> StoreDocument {
        var hand = incoming
        // Preserve all allocated identities, including a branch being undone. Never
        // renumber here: previews and their settlements already refer to revision.
        hand.retainRevisionCeiling(Self.revisionCeiling(for: hand.id, in: current))
        var next = current
        let previousHand = next.hands.first { $0.id == hand.id }
        if !restoringFactIdentity, let previousHand,
           (hand.revision != previousHand.revision || Self.affectsRecordedFacts(previousHand, hand)),
           hand.revision <= Self.revisionCeiling(for: hand.id, in: current) {
            throw LocalStoreError.invalid("新的事实版本必须高于已分配上限；请取消后重新生成编辑或更正预览。")
        }
        if !applyingCorrection, let previousHand, Self.affectsSessionBalances(previousHand, hand) {
            for session in next.sessions ?? [] {
                if session.hands.contains(where: { $0.handID == hand.id && $0.number < session.hands.count }) {
                    throw LocalStoreError.invalid("这手牌已有后续牌局；请先预览场次更正及后续余额，再统一保存。")
                }
            }
        }
        if let index = next.hands.firstIndex(where: { $0.id == hand.id }) {
            next.hands[index] = hand
        } else {
            next.hands.append(hand)
        }
        // Keep notes and bookmarks anchored to their original UUID, including deletion/undo.
        let eventIDs = Set(hand.events.map(\.id))
        for index in next.nodeAnnotations.indices where next.nodeAnnotations[index].handID == hand.id {
            let eventID = next.nodeAnnotations[index].eventID
            if eventIDs.contains(eventID) {
                next.nodeAnnotations[index].removedEvent = nil
            } else if next.nodeAnnotations[index].removedEvent == nil {
                next.nodeAnnotations[index].removedEvent = previousHand?.events.first { $0.id == eventID }
            }
        }
        if var plans = next.rangePlans {
            for index in plans.indices where plans[index].handID == hand.id {
                let eventID = plans[index].eventID
                if eventIDs.contains(eventID) {
                    plans[index].removedEvent = nil
                } else if plans[index].removedEvent == nil {
                    plans[index].removedEvent = previousHand?.events.first { $0.id == eventID }
                }
            }
            next.rangePlans = plans
        }
        if next.selection.lastHandID == hand.id,
           let selected = next.selection.selectedEventID, !eventIDs.contains(selected) {
            next.selection.selectedEventID = nil
        }
        return next
    }

    func delete(id: UUID) throws {
        if let session = sessions.first(where: { $0.hands.contains(where: { $0.handID == id }) }) {
            let error = LocalStoreError.invalid("这手牌属于场次「\(session.title)」，删除会破坏连续余额，暂不能单独删除。")
            saveError = error.localizedDescription
            throw error
        }
        var next = document
        next.hands.removeAll { $0.id == id }
        next.nodeAnnotations.removeAll { $0.handID == id }
        next.rangePlans?.removeAll { $0.handID == id }
        if next.selection.lastHandID == id { next.selection = StoreSelection() }
        try commit(next)
    }

    func upsertSession(_ session: SessionRecord) throws {
        try saveSession(session, hand: nil)
    }

    /// Session linkage and the new hand are committed in one atomic document replacement.
    func saveSession(_ session: SessionRecord, hand: HandRecord?) throws {
        do {
            var next = document
            if let hand { next = try upserting(hand, into: next) }
            var sessions = next.sessions ?? []
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                let previous = sessions[index]
                guard try Self.encodedValue(previous.corrections) == Self.encodedValue(session.corrections) else {
                    throw LocalStoreError.invalid("场次更正记录仅能通过确认预览追加。")
                }
                if !previous.hands.isEmpty {
                    let originalHands = previous.hands.map { "\($0.number)/\($0.handID)" }
                    let retainedHands = session.hands.prefix(previous.hands.count).map { "\($0.number)/\($0.handID)" }
                    let previousFacts = previous.events.filter { $0.effectiveHandNumber <= previous.hands.count }
                    let replacementFacts = session.events.filter { $0.effectiveHandNumber <= previous.hands.count }
                    guard originalHands == retainedHands,
                          previous.initialConfiguration == session.initialConfiguration,
                          try Self.encodedValue(previous.ruleContext) == Self.encodedValue(session.ruleContext),
                          try Self.encodedValue(previous.initialSeats) == Self.encodedValue(session.initialSeats),
                          try Self.encodedValue(previousFacts) == Self.encodedValue(replacementFacts) else {
                        throw LocalStoreError.invalid("场次历史事实已改变；请先预览更正，再统一保存。")
                    }
                }
                sessions[index] = session
            } else { sessions.append(session) }
            next.sessions = sessions
            try commit(next)
        } catch {
            saveError = "场次保存失败：\(error.localizedDescription)"
            throw error
        }
    }

    func commitSessionCorrection(_ preview: SessionCorrectionPreview) throws {
        do {
            guard let index = document.sessions?.firstIndex(where: { $0.id == preview.sessionID }),
                  let current = document.sessions?[index],
                  try SessionReducer.correctionIsCurrent(preview, session: current, hands: document.hands) else {
                throw LocalStoreError.invalid("场次或手牌已在预览后改变，请重新生成更正预览。")
            }
            // Recompute from the original request; never trust caller-supplied replacement payloads.
            let refreshed = previewSessionCorrection(current, request: preview.request)
            guard refreshed.revisionHighWatermarks == preview.revisionHighWatermarks else {
                throw LocalStoreError.invalid("已分配事实版本在预览后改变，请重新生成更正预览。")
            }
            guard refreshed.canCommit else {
                throw LocalStoreError.invalid(refreshed.conflicts.isEmpty ? "更正没有可提交的变化。" : refreshed.conflicts.joined(separator: "；"))
            }
            var next = document
            for hand in refreshed.hands { next = try upserting(hand, into: next, applyingCorrection: true) }
            next.sessions?[index] = refreshed.session
            try commit(next)
        } catch {
            saveError = "场次更正保存失败：\(error.localizedDescription)"
            throw error
        }
    }

    func updateSelection(_ value: StoreSelection) throws {
        var next = document
        next.selection = value
        try commit(next)
    }

    func updatePreferences(_ value: StorePreferences) throws {
        var next = document
        next.preferences = value
        try commit(next)
    }

    func upsertAnnotation(_ annotation: NodeAnnotation) throws {
        var next = document
        var annotation = annotation
        // Freeze linked assumptions so deleting or editing a live plan cannot rewrite a review.
        if let linkedIDs = annotation.rangePlanIDs, annotation.rangeCapture == nil {
            var snapshots = annotation.rangePlanSnapshots ?? []
            for id in linkedIDs where !snapshots.contains(where: { $0.id == id }) {
                if let plan = next.rangePlans?.first(where: { $0.id == id }) { snapshots.append(plan) }
            }
            annotation.rangePlanSnapshots = snapshots
        }
        if annotation.rangeCapture != nil {
            for id in annotation.rangePlanIDs ?? [] {
                guard next.rangePlans?.contains(where: { $0.id == id }) == true else {
                    let error = LocalStoreError.invalid("未保存的临时范围只能嵌入快照，不能标记为方案库链接。")
                    saveError = error.localizedDescription
                    throw error
                }
            }
        }
        if let index = next.nodeAnnotations.firstIndex(where: {
            $0.handID == annotation.handID && $0.eventID == annotation.eventID
        }) {
            var replacement = annotation
            replacement.id = next.nodeAnnotations[index].id
            replacement.removedEvent = next.nodeAnnotations[index].removedEvent
            if replacement.reviewStatus == nil, let status = next.nodeAnnotations[index].reviewStatus {
                let previous = next.nodeAnnotations[index]
                replacement.reviewStatus = status
                replacement.question = previous.question
                replacement.judgment = previous.judgment
                replacement.reflection = previous.reflection
                replacement.rangePlanIDs = previous.rangePlanIDs
                replacement.rangePlanSnapshots = previous.rangePlanSnapshots
                replacement.rangeCapture = previous.rangeCapture
                replacement.completedAt = previous.completedAt
            }
            next.nodeAnnotations[index] = replacement
        } else {
            next.nodeAnnotations.append(annotation)
        }
        try commit(next)
    }

    func upsertRangePlan(_ plan: RangePlan) throws {
        var next = document
        var plans = next.rangePlans ?? []
        if let index = plans.firstIndex(where: { $0.id == plan.id }) {
            let previous = plans[index]
            guard previous.contextKey == plan.contextKey else {
                let error = LocalStoreError.invalid("已有范围方案的节点、视角与研究口径不可更换；请另存为新方案。")
                saveError = error.localizedDescription
                throw error
            }
            do { try Self.validateRangeUpdate(from: previous, to: plan) }
            catch { saveError = "范围方案保存失败：\(error.localizedDescription)"; throw error }
            var replacement = plan
            // Editing a saved missing-node plan cannot silently discard its original anchor.
            if next.hands.first(where: { $0.id == plan.handID })?.events.contains(where: { $0.id == plan.eventID }) != true {
                replacement.removedEvent = plans[index].removedEvent
            }
            plans[index] = replacement
        } else {
            plans.append(plan)
        }
        if plan.isActive {
            for index in plans.indices where plans[index].id != plan.id && plans[index].matches(
                handID: plan.handID, eventID: plan.eventID, subjectID: plan.subjectID,
                targetPlayerID: plan.targetPlayerID, after: plan.after, reveal: plan.reveal,
                scope: plan.resolvedScope
            ) {
                plans[index].isActive = false
            }
        }
        next.rangePlans = plans
        try commit(next)
    }

    func deleteRangePlan(id: UUID) throws {
        var next = document
        next.rangePlans?.removeAll { $0.id == id }
        for index in next.nodeAnnotations.indices {
            next.nodeAnnotations[index].rangePlanIDs?.removeAll { $0 == id }
            // Frozen snapshots remain; only the now nonexistent library link is removed.
        }
        try commit(next)
    }

    func exportData() throws -> Data {
        guard !requiresRecovery else { throw LocalStoreError.recoveryRequired }
        return try Self.encode(document)
    }

    /// Allows users to retain the original unreadable source without interpreting it.
    func originalFileData() throws -> Data { try Data(contentsOf: fileURL) }

    func previewImport(_ data: Data) throws -> ImportPreview {
        let imported = try Self.decode(data)
        try Self.validate(imported)
        return ImportPreview(document: imported)
    }

    /// Call only after the user explicitly chooses to replace existing local data.
    func replaceAll(with preview: ImportPreview) throws {
        try commit(preview.document)
    }

    /// Explicit recovery preserves the current bytes in a separate, unique archive first.
    func recoverByReplacing(with preview: ImportPreview) throws {
        try recover(preview.document)
    }

    func recoverWithEmptyStore() throws { try recover(StoreDocument()) }

    private func recover(_ replacement: StoreDocument) throws {
        do {
            try Self.validate(replacement)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let archive = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("preserved-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: fileURL, to: archive)
            }
            try persist(replacement)
            requiresRecovery = false
            publish(replacement)
            saveError = nil
        } catch {
            saveError = "恢复失败，原数据保持不变：\(error.localizedDescription)"
            throw error
        }
    }

    private func commit(_ next: StoreDocument) throws {
        do {
            guard !requiresRecovery else { throw LocalStoreError.recoveryRequired }
            try Self.validate(next)
            try persist(next)
            publish(next)
            saveError = nil
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
            throw error
        }
    }

    private func persist(_ next: StoreDocument) throws {
        let data = try Self.encode(next)
        guard data.count <= Self.maximumImportBytes else {
            throw LocalStoreError.invalid("数据超过 32 MB，无法保存。")
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func publish(_ next: StoreDocument) {
        document = next
        hands = next.hands
        selection = next.selection
        preferences = next.preferences
        nodeAnnotations = next.nodeAnnotations
        rangePlans = next.rangePlans ?? []
        sessions = next.sessions ?? []
    }

    private static func encodedValue<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func encode(_ value: StoreDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private static func decode(_ data: Data) throws -> StoreDocument {
        guard data.count <= maximumImportBytes else {
            throw LocalStoreError.invalid("备份超过 32 MB，无法读取。")
        }
        // Inspect the version before decoding this version's concrete fields.
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(Header.self, from: data)
        guard header.schemaVersion == 1 else {
            throw LocalStoreError.invalid("不支持的备份版本：\(header.schemaVersion)。")
        }
        return try decoder.decode(StoreDocument.self, from: data)
    }

    private static func validate(_ value: StoreDocument) throws {
        guard value.schemaVersion == 1 else { throw LocalStoreError.invalid("不支持的备份版本。") }
        guard Set(value.hands.map(\.id)).count == value.hands.count else {
            throw LocalStoreError.invalid("备份包含重复牌局标识。")
        }
        var allEventIDs = Set<UUID>()
        for hand in value.hands {
            // Bound externally supplied counters well below machine overflow.
            guard (0...1_000_000_000).contains(hand.revision) else {
                throw LocalStoreError.invalid("牌局版本超出支持范围（0 至 1,000,000,000）。")
            }
            for event in hand.events {
                guard allEventIDs.insert(event.id).inserted else {
                    throw LocalStoreError.invalid("备份包含重复行动标识。")
                }
            }
            try validateHand(hand)
        }
        if let handID = value.selection.lastHandID {
            guard let hand = value.hands.first(where: { $0.id == handID }) else {
                throw LocalStoreError.invalid("恢复位置引用了不存在的牌局。")
            }
            if let eventID = value.selection.selectedEventID,
               !hand.events.contains(where: { $0.id == eventID }) {
                throw LocalStoreError.invalid("恢复位置引用了不存在的行动。")
            }
        } else if value.selection.selectedEventID != nil {
            throw LocalStoreError.invalid("恢复行动缺少所属牌局。")
        }
        try validateSessions(value)
        try validateRangePlans(value)
        var annotationIDs = Set<UUID>()
        var annotationKeys = Set<String>()
        for annotation in value.nodeAnnotations {
            try validateReview(annotation, in: value)
            guard annotationIDs.insert(annotation.id).inserted,
                  annotationKeys.insert("\(annotation.handID)/\(annotation.eventID)").inserted else {
                throw LocalStoreError.invalid("备份包含重复节点笔记。")
            }
            guard let hand = value.hands.first(where: { $0.id == annotation.handID }) else {
                throw LocalStoreError.invalid("节点笔记引用了不存在的牌局。")
            }
            if hand.events.contains(where: { $0.id == annotation.eventID }) {
                guard annotation.removedEvent == nil else {
                    throw LocalStoreError.invalid("现有行动的笔记不可同时标记为已删除。")
                }
            } else {
                guard let removed = annotation.removedEvent, removed.id == annotation.eventID else {
                    throw LocalStoreError.invalid("节点笔记缺少已删除行动的原始记录。")
                }
                if let amount = removed.amount { try validateAmount(amount) }
                guard removed.cards.allSatisfy(\.isValid),
                      validRemovedEvent(removed, handID: hand.id, in: value) else {
                    throw LocalStoreError.invalid("已删除行动的原始记录无效。")
                }
            }
        }
    }

    private static func handVersions(_ handID: UUID, in document: StoreDocument) -> [HandRecord] {
        let current = document.hands.filter { $0.id == handID }
        let historical = (document.sessions ?? []).flatMap { $0.corrections ?? [] }
            .flatMap(\.previousHands).filter { $0.id == handID }
        return current + historical
    }

    private static func revisionCeiling(for handID: UUID, in document: StoreDocument) -> Int {
        var ceiling = handVersions(handID, in: document).map(\.allocatedRevisionCeiling).max() ?? 0
        let frozen = document.nodeAnnotations.flatMap { annotation in
            (annotation.rangePlanSnapshots ?? []) + (annotation.rangeCapture?.dependencyPlanSnapshots ?? [])
        }
        for plan in (document.rangePlans ?? []) + frozen where plan.handID == handID {
            ceiling = max(ceiling, plan.factRevision)
            for change in plan.changeHistory ?? [] {
                ceiling = max(ceiling, max(change.factRevision, change.quickAdjustmentReference?.factRevision ?? 0))
            }
            // Dependency context contains the parent hand identity; do not import
            // another hand's numbering into this target's allocation sequence.
            if let dependency = plan.parentDependency,
               dependency.parentContextKey.split(separator: "|").first.map(String.init) == handID.uuidString {
                ceiling = max(ceiling, dependency.parentFactRevision)
            }
        }
        return ceiling
    }

    private static func validRemovedEvent(_ event: HandEvent, handID: UUID, in document: StoreDocument) -> Bool {
        guard let playerID = event.playerID else { return true }
        if document.hands.first(where: { $0.id == handID })?.players.contains(where: { $0.id == playerID }) == true { return true }
        return handVersions(handID, in: document).contains { hand in
            hand.players.contains(where: { $0.id == playerID }) && hand.events.contains(event)
        }
    }

    private static func validateReview(_ annotation: NodeAnnotation, in document: StoreDocument) throws {
        guard annotation.reviewStatus == nil || annotation.reviewStatus == "pending" || annotation.reviewStatus == "completed" else {
            throw LocalStoreError.invalid("回顾状态必须为待回顾或已完成。")
        }
        guard (annotation.reviewStatus == "completed") == (annotation.completedAt != nil) else {
            throw LocalStoreError.invalid("回顾完成状态与完成时间不一致。")
        }
        let linkedIDs = annotation.rangePlanIDs ?? []
        let snapshots = annotation.rangePlanSnapshots ?? []
        guard Set(linkedIDs).count == linkedIDs.count,
              Set(snapshots.map(\.id)).count == snapshots.count else {
            throw LocalStoreError.invalid("回顾包含重复范围方案引用或快照。")
        }
        if let capture = annotation.rangeCapture {
            let temporaryIDs = Set(capture.temporaryPlanIDs)
            let snapshotIDs = Set(snapshots.map(\.id))
            guard capture.capturedAt.timeIntervalSince1970.isFinite,
                  temporaryIDs.count == capture.temporaryPlanIDs.count,
                  temporaryIDs.isSubset(of: snapshotIDs), temporaryIDs.isDisjoint(with: Set(linkedIDs)),
                  snapshots.allSatisfy({ $0.subjectID == capture.subjectID && $0.after == capture.after
                      && $0.reveal == capture.reveal && $0.resolvedScope == capture.scope }) else {
                throw LocalStoreError.invalid("回顾捕获上下文、临时方案标识或时间无效。")
            }
            let subjectKnown = handVersions(annotation.handID, in: document).contains { $0.players.contains { $0.id == capture.subjectID } }
            guard subjectKnown || (!capture.issues.isEmpty && snapshots.isEmpty) else {
                throw LocalStoreError.invalid("回顾分析对象缺失，须保留明确缺项且不可附加可用范围。")
            }
        }
        let ancestors = annotation.rangeCapture?.dependencyPlanSnapshots ?? []
        guard Set(ancestors.map(\.id)).count == ancestors.count,
              Set(ancestors.map(\.id)).isDisjoint(with: Set(snapshots.map(\.id))) else {
            throw LocalStoreError.invalid("回顾前序快照标识重复。")
        }
        let frozenEvents = annotation.rangeCapture?.dependencyEvents ?? []
        guard Set(frozenEvents.map(\.id)).count == frozenEvents.count else { throw LocalStoreError.invalid("回顾前序节点记录重复。") }
        for event in frozenEvents {
            guard ancestors.contains(where: { $0.eventID == event.id }), event.cards.allSatisfy(\.isValid),
                  validRemovedEvent(event, handID: annotation.handID, in: document) else {
                throw LocalStoreError.invalid("回顾前序节点记录无效。")
            }
            if let amount = event.amount { try validateAmount(amount) }
        }
        for ancestor in ancestors {
            guard ancestor.handID == annotation.handID else { throw LocalStoreError.invalid("回顾前序快照不属于此手牌。") }
            var candidate = ancestor; candidate.isActive = false
            if document.hands.first(where: { $0.id == annotation.handID })?.events.contains(where: { $0.id == ancestor.eventID }) == true {
                candidate.removedEvent = nil
            } else if candidate.removedEvent == nil {
                candidate.removedEvent = frozenEvents.first { $0.id == ancestor.eventID }
            }
            var context = document; context.rangePlans = [candidate]
            try validateRangePlans(context)
        }
        for id in linkedIDs {
            if annotation.rangeCapture != nil,
               document.rangePlans?.contains(where: { $0.id == id }) != true {
                throw LocalStoreError.invalid("回顾方案库链接指向不存在的方案；临时内容必须嵌入快照。")
            }
            guard let plan = snapshots.first(where: { $0.id == id }) ?? document.rangePlans?.first(where: { $0.id == id }),
                  plan.handID == annotation.handID, plan.eventID == annotation.eventID else {
                throw LocalStoreError.invalid("回顾范围方案引用不存在或不属于此节点。")
            }
        }
        for snapshot in snapshots {
            guard snapshot.handID == annotation.handID, snapshot.eventID == annotation.eventID else {
                throw LocalStoreError.invalid("回顾范围快照不属于此节点。")
            }
            if let removed = snapshot.removedEvent {
                guard removed.id == snapshot.eventID, removed.cards.allSatisfy(\.isValid),
                      validRemovedEvent(removed, handID: snapshot.handID, in: document) else {
                    throw LocalStoreError.invalid("回顾范围快照的已删除节点记录无效。")
                }
                if let amount = removed.amount { try validateAmount(amount) }
            }
            // Historical active flags are not live selection; validate each frozen assumption alone.
            var candidate = snapshot
            candidate.isActive = false
            if document.hands.first(where: { $0.id == annotation.handID })?.events.contains(where: { $0.id == annotation.eventID }) == true {
                candidate.removedEvent = nil
            } else if candidate.removedEvent == nil {
                candidate.removedEvent = annotation.removedEvent
            }
            var context = document
            context.rangePlans = [candidate]
            try validateRangePlans(context)
        }
    }

    private static func validateSessions(_ document: StoreDocument) throws {
        let sessions = document.sessions ?? []
        guard Set(sessions.map(\.id)).count == sessions.count else {
            throw LocalStoreError.invalid("场次标识重复。")
        }
        if let selected = document.selection.lastSessionID,
           !sessions.contains(where: { $0.id == selected }) {
            throw LocalStoreError.invalid("恢复位置引用了不存在的场次。")
        }
        var linkedHands = Set<UUID>()
        var eventIDs = Set<UUID>()
        for session in sessions {
            guard (5...9).contains(session.initialConfiguration.tableCapacity) else {
                throw LocalStoreError.invalid("场次桌容量必须为 5–9。")
            }
            guard Set(session.players.map(\.id)).count == session.players.count,
                  Set(session.initialSeats.map(\.playerID)).count == session.initialSeats.count else {
                throw LocalStoreError.invalid("场次初始玩家身份重复。")
            }
            let initialIDs = Set(session.players.map(\.id))
            guard initialIDs == Set(session.initialSeats.map(\.playerID)) else {
                throw LocalStoreError.invalid("场次初始座位与玩家身份不一致。")
            }
            var allIDs = initialIDs
            for event in session.events {
                guard eventIDs.insert(event.id).inserted,
                      (1...session.nextHandNumber).contains(event.effectiveHandNumber) else {
                    throw LocalStoreError.invalid("场次事件身份重复或生效手号无效。")
                }
                switch event.kind {
                case .join(let player, let seat):
                    guard allIDs.insert(player.id).inserted,
                          (0..<session.initialConfiguration.tableCapacity).contains(seat) else {
                        throw LocalStoreError.invalid("加入玩家的身份或座位无效。")
                    }
                case .replaceIdentity(let oldID, let newPlayer):
                    guard allIDs.contains(oldID), allIDs.insert(newPlayer.id).inserted else {
                        throw LocalStoreError.invalid("身份替换引用无效或重复玩家。")
                    }
                case .leave(let id), .sitOut(let id), .returnToTable(let id, _),
                     .buyIn(let id, _), .topUp(let id, _), .cashOut(let id, _), .calibrate(let id, _):
                    guard allIDs.contains(id) else { throw LocalStoreError.invalid("场次事件引用了不存在的玩家。") }
                case .moveSeat(let id, let seat):
                    guard allIDs.contains(id), (0..<session.initialConfiguration.tableCapacity).contains(seat) else {
                        throw LocalStoreError.invalid("换座引用了无效身份或座位。")
                    }
                case .swapSeats(let first, let second):
                    guard first != second, allIDs.contains(first), allIDs.contains(second) else {
                        throw LocalStoreError.invalid("换座双方身份无效。")
                    }
                case .rules: break
                }
            }
            try validateRuleContext(session.ruleContext, playerIDs: allIDs)
            let players = try session.initialSeats.map { seat -> HandPlayer in
                try validateAmount(seat.balance)
                guard let identity = session.players.first(where: { $0.id == seat.playerID }) else {
                    throw LocalStoreError.invalid("初始座位身份不存在。")
                }
                return HandPlayer(id: identity.id, name: identity.name, seat: seat.seat,
                                  startingStack: seat.balance, isHero: identity.isHero)
            }
            let initial = HandRecord(title: session.title, configuration: session.initialConfiguration, players: players)
            let issues = HandReducer.configurationIssues(initial)
            guard issues.isEmpty else { throw LocalStoreError.invalid(issues.joined(separator: "；")) }
            for (index, reference) in session.hands.enumerated() {
                guard reference.number == index + 1,
                      linkedHands.insert(reference.handID).inserted,
                      let hand = document.hands.first(where: { $0.id == reference.handID }),
                      hand.players.allSatisfy({ allIDs.contains($0.id) }) else {
                    throw LocalStoreError.invalid("场次手牌引用缺失、重复、编号不连续或含未知玩家。")
                }
            }
            for reference in session.hands {
                guard let hand = document.hands.first(where: { $0.id == reference.handID }) else { continue }
                let handContext = hand.ruleContext ?? RuleContext()
                let sessionContext = session.ruleContext ?? RuleContext()
                guard handContext.identifier == sessionContext.identifier,
                      handContext.version == sessionContext.version,
                      handContext.parameters == sessionContext.parameters else {
                    throw LocalStoreError.invalid("场次与其手牌的规则标识、版本或参数不一致。")
                }
            }
            try SessionReducer.validateStoredSession(session, hands: document.hands)
            try validateCorrectionArchives(session)
        }
    }

    private static func validateCorrectionArchives(_ session: SessionRecord) throws {
        let archives = session.corrections ?? []
        guard Set(archives.map(\.id)).count == archives.count else {
            throw LocalStoreError.invalid("场次更正记录标识重复。")
        }
        let linkedIDs = Set(session.hands.map(\.handID))
        for archive in archives {
            guard archive.createdAt.timeIntervalSince1970.isFinite,
                  (5...9).contains(archive.previousInitialConfiguration.tableCapacity),
                  Set(archive.previousHands.map(\.id)).count == archive.previousHands.count,
                  Set(archive.previousEvents.map(\.id)).count == archive.previousEvents.count,
                  Set(archive.previousInitialSeats.map(\.playerID)).count == archive.previousInitialSeats.count,
                  Set(archive.previousInitialSeats.map(\.playerID)) == Set(session.players.map(\.id)) else {
                throw LocalStoreError.invalid("场次更正快照的标识、时间或初始名单无效。")
            }
            let initialPlayers = try archive.previousInitialSeats.map { seat -> HandPlayer in
                try validateAmount(seat.balance)
                guard let player = session.players.first(where: { $0.id == seat.playerID }) else {
                    throw LocalStoreError.invalid("场次更正快照的初始身份缺失。")
                }
                return HandPlayer(id: player.id, name: player.name, seat: seat.seat, startingStack: seat.balance, isHero: player.isHero)
            }
            let initial = HandRecord(title: session.title, configuration: archive.previousInitialConfiguration, players: initialPlayers)
            guard HandReducer.configurationIssues(initial).isEmpty else {
                throw LocalStoreError.invalid("场次更正快照的初始配置无效。")
            }
            var identities = Set(session.players.map(\.id))
            for event in archive.previousEvents {
                guard (1...session.nextHandNumber).contains(event.effectiveHandNumber) else {
                    throw LocalStoreError.invalid("历史场次事件生效手号无效。")
                }
                switch event.kind {
                case .join(let player, let seat):
                    guard identities.insert(player.id).inserted,
                          (0..<archive.previousInitialConfiguration.tableCapacity).contains(seat) else {
                        throw LocalStoreError.invalid("历史场次加入身份或座位无效。")
                    }
                case .replaceIdentity(let old, let player):
                    guard identities.contains(old), identities.insert(player.id).inserted else {
                        throw LocalStoreError.invalid("历史身份替换无效。")
                    }
                case .buyIn(let id, let amount), .topUp(let id, let amount), .cashOut(let id, let amount), .calibrate(let id, let amount):
                    try validateAmount(amount)
                    guard identities.contains(id), amount.certainty == .exact, amount.units != nil else {
                        throw LocalStoreError.invalid("历史资金事件身份或金额无效。")
                    }
                case .leave(let id), .sitOut(let id), .returnToTable(let id, _):
                    guard identities.contains(id) else { throw LocalStoreError.invalid("历史事件身份无效。") }
                case .moveSeat(let id, let seat):
                    guard identities.contains(id), (0..<archive.previousInitialConfiguration.tableCapacity).contains(seat) else {
                        throw LocalStoreError.invalid("历史换座身份或座位无效。")
                    }
                case .swapSeats(let first, let second):
                    guard first != second, identities.contains(first), identities.contains(second) else {
                        throw LocalStoreError.invalid("历史换座双方身份无效。")
                    }
                case .rules(let small, let big, let ante):
                    guard small.map({ $0 > 0 }) ?? true, big.map({ $0 > 0 }) ?? true else {
                        throw LocalStoreError.invalid("历史盲注金额无效。")
                    }
                    if let ante {
                        switch ante { case .none: break
                        case .perPlayer(let n), .bigBlind(let n), .button(let n):
                            guard n >= 0 else { throw LocalStoreError.invalid("历史前注金额无效。") }
                        }
                    }
                }
            }
            for hand in archive.previousHands {
                guard linkedIDs.contains(hand.id), (0...1_000_000_000).contains(hand.revision),
                      hand.players.allSatisfy({ identities.contains($0.id) }) else {
                    throw LocalStoreError.invalid("更正快照手牌不属于场次或版本／玩家无效。")
                }
                try validateHand(hand)
            }
            // Only changed original hands are archived: do not claim the whole old chain was replayed.
        }
    }

    private static func validateRangePlans(_ document: StoreDocument) throws {
        let plans = document.rangePlans ?? []
        guard Set(plans.map(\.id)).count == plans.count else {
            throw LocalStoreError.invalid("范围方案标识重复。")
        }
        var activeContexts = Set<String>()
        for plan in plans {
            if plan.isActive {
                guard activeContexts.insert(plan.contextKey).inserted else {
                    throw LocalStoreError.invalid("同一节点、视角和研究口径有多个启用的范围方案。")
                }
            }
            guard (0...1_000_000_000).contains(plan.revision),
                  (0...1_000_000_000).contains(plan.factRevision),
                  plan.weights.count == 1326,
                  plan.weights.allSatisfy({ weight in weight.map { $0.isFinite && (0...100).contains($0) } ?? true }) else {
                throw LocalStoreError.invalid("范围方案版本或组合权重无效；须有 1326 个 0–100 权重或未知值。")
            }
            try validateRangeAudit(plan)
            try validateCatalogReference(plan, in: document)
            guard let hand = document.hands.first(where: { $0.id == plan.handID }) else {
                throw LocalStoreError.invalid("范围方案引用了不存在的牌局。")
            }
            let contextPlayersExist = hand.players.contains(where: { $0.id == plan.subjectID }) && hand.players.contains(where: { $0.id == plan.targetPlayerID })
            let historicalContextExists = plan.factRevision != hand.revision && handVersions(plan.handID, in: document).contains { old in
                old.revision >= plan.factRevision && old.events.contains(where: { $0.id == plan.eventID })
                && old.players.contains(where: { $0.id == plan.subjectID }) && old.players.contains(where: { $0.id == plan.targetPlayerID })
            }
            guard contextPlayersExist || historicalContextExists else {
                throw LocalStoreError.invalid("范围方案引用的玩家缺失，且无同手同节点的历史身份依据。")
            }
            if hand.events.contains(where: { $0.id == plan.eventID }) {
                guard plan.removedEvent == nil else {
                    throw LocalStoreError.invalid("范围方案的现有节点不可同时标记为已删除。")
                }
            } else {
                guard let removed = plan.removedEvent, removed.id == plan.eventID,
                      removed.cards.allSatisfy(\.isValid),
                      validRemovedEvent(removed, handID: hand.id, in: document) else {
                    throw LocalStoreError.invalid("范围方案缺少已删除节点的有效原始记录。")
                }
                if let amount = removed.amount { try validateAmount(amount) }
            }
            // Fact revision mismatches are retained as stale research, never rebased silently.
        }
    }

    private static func validateCatalogReference(_ plan: RangePlan, in document: StoreDocument) throws {
        try validateQuickReferences(plan, in: document)
        guard let reference = plan.catalogReference else { return }
        guard reference.isValid else { throw LocalStoreError.invalid("范围来源引用的身份、版本或修订结构无效。") }
        if reference.actionId != nil {
            let baseline = try reverseRangeChanges(plan.changeHistory ?? [], from: plan.weights)
            guard plan.after, reference.parentWeightsHash == RangeCatalogRepository.weightsHash(baseline) else {
                throw LocalStoreError.invalid("范围行动更新的先验记录与修订链不符。")
            }
            if let modelID = reference.modelChangeID {
                guard let first = plan.changeHistory?.first, first.id == modelID, first.factRevision == plan.factRevision else {
                    throw LocalStoreError.invalid("范围行动更新缺少同事实版本的首笔模型修订。")
                }
            }
        }
        let repository = RangeCatalogRepository.bundled
        // Missing packages do not erase imported hypotheses or block recovery of the whole backup.
        guard repository.hasPackage(reference) else { return }
        let provenance = repository.provenanceIssues(reference)
        guard provenance.isEmpty else { throw LocalStoreError.invalid(provenance.joined(separator: "；")) }
        // An exact historical input can validate its old source; absent facts cannot confer current trust.
        guard let facts = handVersions(plan.handID, in: document).first(where: { $0.revision == plan.factRevision }),
              plan.removedEvent == nil else { return }
        let issues = repository.referenceIssues(reference, plan: plan, hand: facts)
        guard issues.isEmpty else { throw LocalStoreError.invalid(issues.joined(separator: "；")) }
    }

    private static func validateQuickReferences(_ plan: RangePlan, in document: StoreDocument) throws {
        let repository = RangeCatalogRepository.bundled
        var input = try reverseRangeChanges(plan.changeHistory ?? [], from: plan.weights)
        for entry in plan.changeHistory ?? [] {
            if let reference = entry.quickAdjustmentReference, repository.hasQuickPackage(reference) {
                let facts = handVersions(plan.handID, in: document).first { $0.revision == reference.factRevision }
                let issues = repository.quickChangeIssues(reference, entry: entry, input: input, plan: plan, hand: facts)
                guard issues.isEmpty else { throw LocalStoreError.invalid(issues.joined(separator: "；")) }
            }
            for change in entry.changes { input[change.index] = change.after }
        }
    }

    private static func validateRangeAudit(_ plan: RangePlan) throws {
        if let dependency = plan.parentDependency {
            guard dependency.isValid,
                  plan.catalogReference?.actionId == nil || dependency.parentWeightsHash == plan.catalogReference?.parentWeightsHash else {
                throw LocalStoreError.invalid("范围先验依赖的版本、身份或内容指纹无效。")
            }
        }
        // Dependency validity is runtime state: deleted/changed parents and legacy bindings
        // remain recoverable in backups. Never validate frozen history against live parents.
        let history = plan.changeHistory ?? []
        guard Set(history.map(\.id)).count == history.count,
              plan.updatedAt.timeIntervalSince1970.isFinite,
              plan.judgmentRecordedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
            throw LocalStoreError.invalid("范围修改审计标识重复或时间无效。")
        }
        for change in history {
            guard (0...1_000_000_000).contains(change.factRevision),
                  change.date.timeIntervalSince1970.isFinite,
                  !change.changes.isEmpty,
                  Set(change.changes.map(\.index)).count == change.changes.count else {
                throw LocalStoreError.invalid("范围修改审计的版本、时间或组合记录无效。")
            }
            for item in change.changes {
                guard (0..<1326).contains(item.index),
                      validRangeWeight(item.before), validRangeWeight(item.after),
                      item.before != item.after else {
                    throw LocalStoreError.invalid("范围审计组合索引或修改前后权重无效。")
                }
            }
        }
        // Optional semantic references add trust evidence without changing old manual backups.
        var input = try reverseRangeChanges(history, from: plan.weights)
        var applied: [RangePlanChange] = []
        for entry in history {
            if let reference = entry.quickAdjustmentReference {
                guard entry.undoOfChangeID == nil, reference.isValid, reference.contextKey == plan.contextKey,
                      reference.factRevision == entry.factRevision,
                      reference.inputWeightsHash == RangeCatalogRepository.weightsHash(input),
                      entry.changes.allSatisfy({ !RangePlan.combinations[$0.index].blocked(by: Set(reference.blockers)) && $0.before != nil && $0.after != nil }) else {
                    throw LocalStoreError.invalid("快捷操作来源、先验或阻断审计不符。")
                }
            }
            if let targetID = entry.undoOfChangeID {
                var undone = Set<UUID>()
                var candidate: RangePlanChange?
                for previous in applied.reversed() {
                    if let id = previous.undoOfChangeID { undone.insert(id); continue }
                    if !undone.contains(previous.id) { candidate = previous; break }
                }
                guard let target = candidate, target.id == targetID,
                      target.changes.map({ RangePlanChange.WeightChange(index: $0.index, before: $0.after, after: $0.before) }) == entry.changes else {
                    throw LocalStoreError.invalid("撤销须完整逆转最后有效修改，不能重复或跨越后续编辑。")
                }
            }
            for item in entry.changes { input[item.index] = item.after }
            applied.append(entry)
        }
    }

    private static func validateRangeUpdate(from previous: RangePlan, to replacement: RangePlan) throws {
        guard previous.catalogReference == replacement.catalogReference, previous.parentDependency == replacement.parentDependency else {
            throw LocalStoreError.invalid("已保存方案的来源或先验依赖不可改写；请显式重新生成新假设。")
        }
        let prior = previous.changeHistory ?? []
        let proposed = replacement.changeHistory ?? []
        guard proposed.count >= prior.count, Array(proposed.prefix(prior.count)) == prior else {
            throw LocalStoreError.invalid("已保存的范围修改审计不可删除或改写。")
        }
        // Validate before indexing, including all 1326 current values and new audit entries.
        guard replacement.isValidWeights else { throw LocalStoreError.invalid("范围权重格式无效。") }
        try validateRangeAudit(replacement)
        let appended = Array(proposed.dropFirst(prior.count))
        guard try reverseRangeChanges(appended, from: replacement.weights) == previous.weights else {
            throw LocalStoreError.invalid("范围权重修改必须与追加的审计记录完整一致。")
        }
    }

    private static func validRangeWeight(_ value: Double?) -> Bool {
        value.map { $0.isFinite && (0...100).contains($0) } ?? true
    }

    private static func reverseRangeChanges(_ changes: [RangePlanChange], from finalWeights: [Double?]) throws -> [Double?] {
        var weights = finalWeights
        for change in changes.reversed() {
            for item in change.changes {
                guard weights.indices.contains(item.index), weights[item.index] == item.after else {
                    throw LocalStoreError.invalid("范围审计记录与当前权重或相邻修改不一致。")
                }
                weights[item.index] = item.before
            }
        }
        return weights
    }

    private static func validateHand(_ hand: HandRecord) throws {
        guard hand.revision >= 0, hand.revision <= HandRecord.maximumFactRevision else {
            throw LocalStoreError.invalid("牌局事实版本超出支持范围（0 至 1,000,000,000）。")
        }
        if let watermark = hand.revisionHighWatermark,
           watermark < hand.revision || watermark > HandRecord.maximumFactRevision {
            throw LocalStoreError.invalid("牌局事实版本或已分配版本上限无效（0 至 1,000,000,000；上限不能小于当前版本）。")
        }
        try validateRuleContext(hand.ruleContext, playerIDs: Set(hand.players.map(\.id)))
        let remembered = hand.rememberedPots ?? []
        guard Set(remembered.map(\.id)).count == remembered.count else {
            throw LocalStoreError.invalid("记忆底池记录标识重复。")
        }
        var rememberedNodes = Set<String>()
        for memory in remembered {
            let key = "\(memory.nodeEventID?.uuidString ?? "initial")/\(memory.after)"
            guard rememberedNodes.insert(key).inserted, memory.recordedAt.timeIntervalSince1970.isFinite else {
                throw LocalStoreError.invalid("记忆底池节点重复或记录时间无效。")
            }
            try validateAmount(memory.amount)
            // Removed node references remain visible reconciliation records, never auto-deleted.
        }
        guard Set(hand.players.map(\.id)).count == hand.players.count else {
            throw LocalStoreError.invalid("牌局包含重复玩家标识。")
        }
        for player in hand.players {
            try validateAmount(player.startingStack)
            guard player.holeCards.count <= 2, player.holeCards.allSatisfy(\.isValid) else {
                throw LocalStoreError.invalid("玩家底牌格式无效。")
            }
        }
        for event in hand.events {
            if let amount = event.amount { try validateAmount(amount) }
            guard event.cards.allSatisfy(\.isValid) else {
                throw LocalStoreError.invalid("行动包含无效牌面。")
            }
        }
        // Event-order and action-legality conflicts remain durable drafts (B11).
        // Configuration-level failures are rejected by the shared domain reducer.
        let projection = HandReducer.project(hand)
        if let issue = projection.issues.first(where: { $0.eventID == nil }) {
            throw LocalStoreError.invalid(issue.message)
        }
        try validateSettlements(hand)
    }

    private static func validateRuleContext(_ context: RuleContext?, playerIDs: Set<UUID>) throws {
        guard let context else { return } // Legacy records mean regular-nlhe v1.
        guard !context.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              context.version > 0,
              Set(context.additionalSettlements.map(\.id)).count == context.additionalSettlements.count else {
            throw LocalStoreError.invalid("规则标识、版本或独立附加结算标识无效。")
        }
        for settlement in context.additionalSettlements {
            guard !settlement.ruleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  settlement.ruleVersion > 0,
                  settlement.recordedAt.timeIntervalSince1970.isFinite else {
                throw LocalStoreError.invalid("附加结算的规则标识、版本或时间无效。")
            }
            for transfer in settlement.transfers {
                guard playerIDs.contains(transfer.playerID) else {
                    throw LocalStoreError.invalid("独立附加结算引用了不存在的玩家。")
                }
                try validateAmount(transfer.amount)
            }
        }
        // Unknown identifiers, parameters and state are opaque persisted data, not implemented rules.
        // Their independent transfers are never added to ordinary pot or balance calculations here.
    }

    private static func validateSettlements(_ hand: HandRecord) throws {
        let records = (hand.settlement.map { [$0] } ?? []) + (hand.settlementHistory ?? [])
        guard Set(records.map(\.id)).count == records.count else {
            throw LocalStoreError.invalid("结算记录标识重复。")
        }
        let playerIDs = Set(hand.players.map(\.id))
        for record in records {
            guard (0...hand.revision).contains(record.factRevision) else {
                throw LocalStoreError.invalid("结算引用了无效事实版本。")
            }
            let isCurrent = hand.settlement?.id == record.id && record.isCurrent(for: hand)
            if !isCurrent && record.invalidatedAt == nil && hand.ruleApplicabilityIssue == nil {
                throw LocalStoreError.invalid("历史结算必须明确标记失效。")
            }
            guard Set(record.pots.map(\.id)).count == record.pots.count,
                  record.pots.enumerated().allSatisfy({ $0.offset == $0.element.id }) else {
                throw LocalStoreError.invalid("结算底池标识重复或不连续。")
            }
            try validatePayments(record.refunds, allowedIDs: playerIDs)
            for pot in record.pots {
                let eligible = Set(pot.eligibleIDs)
                let winners = Set(pot.winnerIDs)
                guard pot.units >= 0,
                      !eligible.isEmpty, eligible.count == pot.eligibleIDs.count,
                      eligible.isSubset(of: playerIDs),
                      !winners.isEmpty, winners.count == pot.winnerIDs.count,
                      winners.isSubset(of: eligible),
                      pot.oddChipFirst.map({ winners.contains($0) }) ?? true,
                      pot.source != .mixed else {
                    throw LocalStoreError.invalid("结算底池的金额、资格或赢家无效。")
                }
                try validatePayments(pot.payments, allowedIDs: winners)
                guard Set(pot.payments.map(\.playerID)) == winners,
                      try checkedSum(pot.payments.map(\.units)) == pot.units else {
                    throw LocalStoreError.invalid("结算底池分配不守恒。")
                }
                if let inputs = pot.amountInputs {
                    guard let inputUnit = pot.amountInputUnit, inputUnit.value != nil,
                          inputs.count == winners.count, Set(inputs.map(\.playerID)) == winners,
                          inputs.allSatisfy({ input in
                              guard let units = inputUnit.parse(input.amount)?.units else { return false }
                              return pot.payments.contains { $0.playerID == input.playerID && $0.units == units }
                          }), !isCurrent || inputUnit == hand.configuration.chipUnit else {
                        throw LocalStoreError.invalid("结算金额核对记录包含重复玩家、无资格玩家或非法金额。")
                    }
                    let base = pot.units / Int64(winners.count)
                    let hasRemainder = pot.units % Int64(winners.count) > 0
                    guard pot.payments.allSatisfy({ $0.units == base || (hasRemainder && $0.units == base + 1) }) else {
                        throw LocalStoreError.invalid("结算金额核对记录不符合合法平分与零头规则。")
                    }
                } else if pot.amountInputUnit != nil {
                    throw LocalStoreError.invalid("结算金额核对单位缺少对应输入记录。")
                }
            }
            // Also reject totals whose aggregation cannot be represented.
            _ = try checkedSum(record.refunds.map(\.units) + record.pots.map(\.units))
            let sources = Set(record.pots.map { $0.source.rawValue })
            let source: SettlementSource = sources.count == 1 ? (record.pots.first?.source ?? .manual) : .mixed
            guard record.source == source,
                  Set(record.finalBalances.map(\.playerID)) == playerIDs,
                  record.finalBalances.count == playerIDs.count else {
                throw LocalStoreError.invalid("结算来源或最终余额的玩家集合无效。")
            }
            for balance in record.finalBalances { try validateAmount(balance.amount) }
            if isCurrent && hand.ruleApplicabilityIssue == nil {
                let selections = Dictionary(uniqueKeysWithValues: record.pots.map {
                    ($0.id, SettlementSelection(winnerIDs: $0.winnerIDs, oddChipFirst: $0.oddChipFirst, amountInputs: $0.amountInputs))
                })
                let expected = HandSettlement.preview(hand, selections: selections)
                guard expected.canConfirm, expected.source == record.source,
                      samePayments(expected.refunds, record.refunds),
                      expected.pots.count == record.pots.count,
                      zip(expected.pots, record.pots).allSatisfy({ a, b in
                          a.id == b.id && a.units == b.units && Set(a.eligibleIDs) == Set(b.eligibleIDs)
                          && Set(a.winnerIDs) == Set(b.winnerIDs) && a.source == b.source
                          && a.oddChipFirst == b.oddChipFirst && samePayments(a.payments, b.payments)
                      }),
                      Dictionary(uniqueKeysWithValues: expected.finalBalances.map { ($0.playerID, $0.amount) })
                        == Dictionary(uniqueKeysWithValues: record.finalBalances.map { ($0.playerID, $0.amount) }) else {
                    throw LocalStoreError.invalid("当前结算与牌局事实重新计算的结果不一致。")
                }
            }
            // Unsupported rule contexts preserve ordinary settlement bytes structurally only;
            // applicability guards prohibit treating them as current ordinary-rule results.
            // Stale records have no historical input snapshot: structural consistency only.
        }
    }

    private static func validatePayments(_ payments: [SettlementPayment], allowedIDs: Set<UUID>) throws {
        guard Set(payments.map(\.playerID)).count == payments.count,
              payments.allSatisfy({ allowedIDs.contains($0.playerID) && $0.units >= 0 }) else {
            throw LocalStoreError.invalid("结算支付包含重复玩家、未知玩家或负金额。")
        }
        _ = try checkedSum(payments.map(\.units))
    }

    private static func checkedSum(_ values: [Int64]) throws -> Int64 {
        var total: Int64 = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard value >= 0, !overflow else { throw LocalStoreError.invalid("结算金额总和超出有效范围。") }
            total = next
        }
        return total
    }

    private static func samePayments(_ lhs: [SettlementPayment], _ rhs: [SettlementPayment]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return Dictionary(uniqueKeysWithValues: lhs.map { ($0.playerID, $0.units) })
            == Dictionary(uniqueKeysWithValues: rhs.map { ($0.playerID, $0.units) })
    }

    private static func validateAmount(_ amount: ChipAmount) throws {
        if let units = amount.units {
            guard units >= 0, amount.certainty != .unknown else {
                throw LocalStoreError.invalid("筹码金额与精度标记无效。")
            }
        } else if amount.certainty != .unknown {
            throw LocalStoreError.invalid("缺失筹码金额必须标记为未知。")
        }
    }
}
