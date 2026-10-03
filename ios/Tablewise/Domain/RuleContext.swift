import Foundation

/// Persistence boundary only. No variant behavior or extra payout is implemented in this release.
struct RuleContext: Codable, Sendable {
    var identifier: String = "regular-nlhe"
    var version: Int = 1
    var parameters: [String: String] = [:]
    /// Hand and session each own their own context, keeping per-hand and cross-hand state separate.
    var additionalState: [String: String] = [:]
    var additionalSettlements: [AdditionalRuleSettlement] = []

    var applicabilityIssue: String? {
        guard identifier == "regular-nlhe", version == 1 else { return "当前规则或版本尚不支持；保留原始记录，暂停普通规则推导与分析。" }
        guard parameters.isEmpty, additionalState.isEmpty, additionalSettlements.isEmpty else {
            return "当前记录包含尚不支持的附加规则数据；不能套用普通底池、结算或筹码 EV。"
        }
        return nil
    }
}
enum RuleTransferDirection: String, Codable, Sendable { case credit, debit }
struct RuleTransfer: Codable, Sendable {
    var playerID: UUID
    var direction: RuleTransferDirection
    var amount: ChipAmount
}
/// Deliberately separate from HandEvent and ordinary pot settlement. Stored, never applied by NLHE.
struct AdditionalRuleSettlement: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var ruleIdentifier: String
    var ruleVersion: Int
    var recordedAt: Date = Date()
    var transfers: [RuleTransfer]
    var source: String
}
