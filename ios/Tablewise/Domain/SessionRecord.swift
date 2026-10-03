import Foundation

/// Identity outlives seats and hands. Same names never imply the same person.
struct SessionPlayer: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var isHero: Bool = false
    var notes: String = ""
}
enum SessionParticipation: String, Codable, Sendable { case playing, sittingOut, waiting, left }
struct SessionSeat: Codable, Sendable, Identifiable {
    var playerID: UUID
    var seat: Int
    var balance: ChipAmount
    var participation: SessionParticipation = .playing
    var id: UUID { playerID }
}
enum SessionStatus: String, Codable, Sendable { case active, ended }

/// Personnel and external funds are separate facts; neither changes hand actions or pot eligibility.
enum SessionEventKind: Codable, Sendable {
    case join(player: SessionPlayer, seat: Int)
    case leave(playerID: UUID)
    case sitOut(playerID: UUID)
    case returnToTable(playerID: UUID, participate: Bool)
    case moveSeat(playerID: UUID, seat: Int)
    case swapSeats(first: UUID, second: UUID)
    case replaceIdentity(oldPlayerID: UUID, newPlayer: SessionPlayer)
    case buyIn(playerID: UUID, amount: ChipAmount)
    case topUp(playerID: UUID, amount: ChipAmount)
    case cashOut(playerID: UUID, amount: ChipAmount)
    case calibrate(playerID: UUID, measuredBalance: ChipAmount)
    /// Optional fields deliberately preserve independently edited blind values.
    case rules(smallBlind: Int64?, bigBlind: Int64?, ante: AnteRule?)
}
struct SessionEvent: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var effectiveHandNumber: Int
    var kind: SessionEventKind
    var note: String = ""
    var cancelledAt: Date? = nil
}
struct SessionHandReference: Codable, Sendable, Identifiable {
    var handID: UUID
    var number: Int
    /// The immutable deal-time roster lives on the referenced HandRecord.
    var id: UUID { handID }
}
struct SessionRecord: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var status: SessionStatus = .active
    var initialConfiguration: HandConfiguration
    var players: [SessionPlayer]
    var initialSeats: [SessionSeat]
    var hands: [SessionHandReference] = []
    var events: [SessionEvent] = []
    var corrections: [SessionCorrectionArchive]? = nil
    var ruleContext: RuleContext? = nil
    var gameFormat: HandGameFormat? = nil
    var ruleApplicabilityIssue: String? { ruleContext?.applicabilityIssue }
    var nextHandNumber: Int { hands.count + 1 }
}
struct SessionFinanceEntry: Sendable, Identifiable {
    var event: SessionEvent
    var playerID: UUID
    var before: ChipAmount
    var after: ChipAmount
    var delta: ChipAmount {
        switch event.kind {
        case .buyIn(_, let amount), .topUp(_, let amount): return amount
        case .cashOut(_, let amount): return ChipAmount.zero.subtracting(amount)
        default: return after.subtracting(before)
        }
    }
    var id: UUID { event.id }
}
struct SessionNextHandPreview: Sendable {
    var number: Int
    var configuration: HandConfiguration
    var identities: [SessionPlayer]
    var seats: [SessionSeat]
    var players: [HandPlayer]
    var positions: [UUID: String]
    var pendingEvents: [SessionEvent]
    var finance: [SessionFinanceEntry]
    var issues: [String]
    var unconfirmedBalanceIDs: [UUID]
    var canStart: Bool { issues.isEmpty }
}
struct SessionMetric: Sendable {
    var count: Int = 0
    var opportunities: Int = 0
    var excludedHands: Int = 0
    var percent: Double? { opportunities == 0 ? nil : Double(count) / Double(opportunities) * 100 }
}
struct SessionPlayerStatistics: Sendable {
    var playerID: UUID
    var dealtHands: Int = 0
    var vpip = SessionMetric()
    var pfr = SessionMetric()
    var threeBet = SessionMetric()
    var settledHands: Int = 0
    var unsettledHands: Int = 0
    var pokerNet: ChipAmount = .zero
    var bigBlindNet: Double = 0
    var exclusions: [String] = []
}
enum SessionError: LocalizedError {
    case invalid(String)
    case calibrationCorrectionRulePending
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .calibrationCorrectionRulePending: return "此次历史更正跨过筹码校准；校准衔接规则尚待确认，暂不能保存此更正。"
        }
    }
}
