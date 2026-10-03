import Foundation

enum ValueCertainty: String, Codable, CaseIterable, Sendable { case exact, approximate, unknown }

struct ChipAmount: Codable, Hashable, Sendable {
    var units: Int64?
    var certainty: ValueCertainty
    var source: String
    init(units: Int64?, certainty: ValueCertainty = .exact, source: String = "手动录入") {
        self.units = units
        self.certainty = units == nil ? .unknown : certainty
        self.source = source
    }
    static var unknown: Self { .init(units: nil, source: "未知") }
    static var zero: Self { .init(units: 0, source: "推导") }
    func adding(_ other: Self) -> Self {
        guard let a = units, let b = other.units else { return .unknown }
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { return .unknown }
        return .init(units: value, certainty: certainty == .exact && other.certainty == .exact ? .exact : .approximate, source: "事件推导")
    }
    func subtracting(_ other: Self) -> Self {
        guard let n = other.units, n != Int64.min else { return .unknown }
        return adding(.init(units: -n, certainty: other.certainty, source: other.source))
    }
}

struct ChipUnit: Codable, Hashable, Sendable {
    var decimal: String
    init(decimal: String = "1") { self.decimal = decimal }
    var value: Decimal? {
        guard decimal.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let d = Decimal(string: decimal, locale: Locale(identifier: "en_US_POSIX")), d > 0 else { return nil }
        return d
    }
    func parse(_ input: String, certainty: ValueCertainty = .exact) -> ChipAmount? {
        guard input.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let unit = value, let number = Decimal(string: input, locale: Locale(identifier: "en_US_POSIX")), number >= 0 else { return nil }
        var quotient = number / unit
        var rounded = Decimal()
        NSDecimalRound(&rounded, &quotient, 0, .plain)
        guard rounded == quotient, rounded <= Decimal(Int64.max) else { return nil }
        return ChipAmount(units: NSDecimalNumber(decimal: rounded).int64Value, certainty: certainty)
    }
    func format(_ amount: ChipAmount) -> String {
        guard let units = amount.units, let unit = value else { return "未知" }
        return (amount.certainty == .approximate ? "≈" : "") + NSDecimalNumber(decimal: Decimal(units) * unit).stringValue
    }
    func format(units: Int64) -> String { format(.init(units: units)) }
}

enum CardSuit: String, Codable, CaseIterable, Sendable {
    case clubs, diamonds, hearts, spades
    var symbol: String { switch self { case .clubs: "♣"; case .diamonds: "♦"; case .hearts: "♥"; case .spades: "♠" } }
}
struct PokerCard: Codable, Hashable, Sendable, Identifiable {
    var rank: Int
    var suit: CardSuit
    var id: String { "\(rank)-\(suit.rawValue)" }
    var label: String { ([11:"J",12:"Q",13:"K",14:"A"][rank] ?? String(rank)) + suit.symbol }
    var isValid: Bool { (2...14).contains(rank) }
}

enum HandStreet: String, Codable, CaseIterable, Sendable {
    case preflop, flop, turn, river
    var title: String { switch self { case .preflop: "翻前"; case .flop: "翻牌"; case .turn: "转牌"; case .river: "河牌" } }
    var next: Self? { switch self { case .preflop: .flop; case .flop: .turn; case .turn: .river; case .river: nil } }
    var cardCount: Int { switch self { case .preflop: 0; case .flop: 3; case .turn, .river: 1 } }
    var order: Int { switch self { case .preflop: 0; case .flop: 1; case .turn: 2; case .river: 3 } }
}
enum AnteRule: Codable, Hashable, Sendable {
    case none
    case perPlayer(Int64)
    case bigBlind(Int64)
    case button(Int64)
}
struct HandConfiguration: Codable, Hashable, Sendable {
    var tableCapacity: Int
    var buttonSeat: Int
    var smallBlind: Int64
    var bigBlind: Int64
    var ante: AnteRule = .none
    var chipUnit: ChipUnit = .init()
}
struct HandPlayer: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var seat: Int
    var startingStack: ChipAmount
    var holeCards: [PokerCard] = []
    var isHero: Bool = false
}
enum HandEventKind: String, Codable, CaseIterable, Sendable {
    case smallBlind, bigBlind, ante, deadBlind, liveBlind, fold, check, call, bet, raiseTo, allIn, deal
    var isForced: Bool { [.smallBlind, .bigBlind, .ante, .deadBlind, .liveBlind].contains(self) }
    var title: String {
        switch self {
        case .smallBlind: "小盲"; case .bigBlind: "大盲"; case .ante: "前注"; case .deadBlind: "补盲（仅入池）"; case .liveBlind: "补盲（计入本街）"
        case .fold: "弃牌"; case .check: "过牌"; case .call: "跟注到"; case .bet: "下注到"; case .raiseTo: "加注到"; case .allIn: "全下到"; case .deal: "发牌"
        }
    }
}
struct HandEvent: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var street: HandStreet
    var playerID: UUID? = nil
    var kind: HandEventKind
    /// Voluntary money actions persist the street total; forced events persist the amount paid.
    var amount: ChipAmount? = nil
    var cards: [PokerCard] = []
    var source: String = "手动录入"
}
struct RememberedPot: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    /// nil identifies the initial state, never an implicit moving latest node.
    var nodeEventID: UUID?
    var after: Bool
    var amount: ChipAmount
    var recordedAt: Date = Date()
}

/// Both formats use ordinary NLHE chip EV; tournament does not enable ICM or payout rules.
enum HandGameFormat: String, Codable, CaseIterable, Sendable {
    case cash, tournament
    var title: String {
        switch self { case .cash: "现金场"; case .tournament: "锦标赛 · 筹码 EV" }
    }
}

struct HandRecord: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var revision: Int = 0
    /// Highest allocated fact identity. Optional so pre-existing records decode unchanged.
    /// Undo restores revision but retains this ceiling for the next new fact branch.
    var revisionHighWatermark: Int? = nil
    var configuration: HandConfiguration
    var players: [HandPlayer]
    var events: [HandEvent] = []
    var notes: String = ""
    var settlement: HandSettlementRecord? = nil
    var settlementHistory: [HandSettlementRecord]? = nil
    var rememberedPots: [RememberedPot]? = nil
    var ruleContext: RuleContext? = nil
    /// nil preserves an unspecified format, including records made before this field existed.
    var gameFormat: HandGameFormat? = nil
    var ruleApplicabilityIssue: String? { ruleContext?.applicabilityIssue }
    func rememberedPot(nodeEventID: UUID?, after: Bool) -> RememberedPot? {
        rememberedPots?.last { $0.nodeEventID == nodeEventID && $0.after == after }
    }
    func potNeedsReconciliation(nodeEventID: UUID?, after: Bool) -> Bool {
        guard let memory = rememberedPot(nodeEventID: nodeEventID, after: after), let remembered = memory.amount.units else { return false }
        let projection = HandReducer.project(self)
        let snapshot: HandSnapshot
        if let nodeEventID {
            guard let node = projection.nodes.first(where: { $0.id == nodeEventID }) else { return true }
            snapshot = after ? node.after : node.before
        } else { snapshot = projection.initial }
        guard !snapshot.blocked, let derived = snapshot.pot.units else { return true }
        return remembered != derived
    }
    mutating func append(_ event: HandEvent) { events.append(event); touch() }
    /// Place a newly remembered deal at its street boundary without moving existing facts.
    mutating func insertRememberedDeal(_ event: HandEvent) {
        guard event.kind == .deal else { return }
        let index = events.firstIndex { $0.street.order >= event.street.order } ?? events.endIndex
        events.insert(event, at: index)
        touch()
    }
    /// An explicit repair for old records saved in entry order (for example Turn, then Flop).
    mutating func repositionDeal(eventID: UUID) {
        guard let index = events.firstIndex(where: { $0.id == eventID && $0.kind == .deal }) else { return }
        let event = events.remove(at: index)
        let destination = events.firstIndex { $0.street.order >= event.street.order } ?? events.endIndex
        events.insert(event, at: destination)
        if index != destination { touch() }
    }
    func dealIsOutOfOrder(eventID: UUID) -> Bool {
        guard let index = events.firstIndex(where: { $0.id == eventID && $0.kind == .deal }) else { return false }
        return events.prefix(index).contains { $0.street.order > events[index].street.order }
    }
    mutating func replace(_ event: HandEvent) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index] = event; touch()
    }
    mutating func remove(eventID: UUID) { events.removeAll { $0.id == eventID }; touch() }
    static let maximumFactRevision = 1_000_000_000
    var allocatedRevisionCeiling: Int {
        ([revision, revisionHighWatermark ?? revision]
         + (settlement.map { [$0.factRevision] } ?? [])
         + (settlementHistory ?? []).map(\.factRevision)).max() ?? revision
    }
    mutating func retainRevisionCeiling(_ ceiling: Int) {
        revisionHighWatermark = max(allocatedRevisionCeiling, ceiling)
    }
    mutating func touch() {
        if settlement != nil && settlement?.invalidatedAt == nil { settlement?.invalidatedAt = Date() }
        let ceiling = allocatedRevisionCeiling
        // An exhausted counter stays invalid and is rejected by atomic store validation;
        // it must never wrap or reuse an identity, even for untrusted imported counters.
        revision = ceiling < Self.maximumFactRevision ? ceiling + 1 : Self.maximumFactRevision + 1
        revisionHighWatermark = revision
        updatedAt = Date()
    }
}
struct HandIssue: Identifiable, Sendable {
    var eventID: UUID?
    var message: String
    var id: String { "\(eventID?.uuidString ?? "configuration")-\(message)" }
}
struct PlayerSnapshot: Identifiable, Sendable {
    var id: UUID
    var remaining: ChipAmount
    var streetContribution: ChipAmount = .zero
    var totalContribution: ChipAmount = .zero
    var folded: Bool = false
    var allIn: Bool = false
    var lastActedAt: Int64? = nil
}
struct HandSnapshot: Sendable {
    var street: HandStreet = .preflop
    /// Independently observed public cards. These never authorize actions or calculations.
    var knownStreet: HandStreet? = nil
    var knownBoard: [HandStreet: [PokerCard]] = [:]
    var board: [PokerCard] = []
    var players: [PlayerSnapshot]
    var pot: ChipAmount = .zero
    var currentBet: Int64 = 0
    var lastFullRaise: Int64
    var actorID: UUID? = nil
    var roundComplete: Bool = false
    var handComplete: Bool = false
    var blocked: Bool = false
    var forcedContributionsComplete: Bool = false
    var hasUncertainty: Bool { players.contains { $0.remaining.certainty != .exact || $0.totalContribution.certainty != .exact } || pot.certainty != .exact }
    var displayStreet: HandStreet { knownStreet ?? street }
    var hasBoardGap: Bool {
        guard displayStreet.order >= HandStreet.flop.order else { return false }
        return HandStreet.allCases.filter { $0.order > 0 && $0.order <= displayStreet.order }
            .contains { knownBoard[$0]?.count != $0.cardCount }
    }
    func player(_ id: UUID) -> PlayerSnapshot? { players.first { $0.id == id } }
}
struct HandNode: Identifiable, Sendable {
    var event: HandEvent
    var before: HandSnapshot
    var after: HandSnapshot
    var issues: [HandIssue]
    var id: UUID { event.id }
}
struct HandProjection: Sendable {
    var initial: HandSnapshot
    var nodes: [HandNode]
    var latest: HandSnapshot
    var issues: [HandIssue]
}
struct LegalActions: Sendable {
    var actorID: UUID?
    var canCheck = false
    var canFold = false
    var canCall = false
    var canRaise = false
    var canAllIn = false
    var callTo: Int64 = 0
    var minimumRaiseTo: Int64 = 0
    var maximumTo: Int64? = nil
}
