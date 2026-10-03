import Foundation

/// Mirrors range-pack.v1. A decoded pack is not an approved production catalog.
struct RangeCatalogPack: Decodable {
    let schemaVersion: String
    let packageVersion: String
    let id: String
    let createdAt: String
    let encoding: Encoding
    let sources: [Source]
    let contexts: [Context]
    let nodes: [Node]
    let links: [Link]
    let publication: Publication
    struct Encoding: Decodable { let id: String }
    struct Publication: Decodable { let status: String; let automaticMatchingAllowed: Bool; let blockingReasons: [String] }
    struct File: Decodable { let path: String; let sha256: String }
    struct Source: Decodable {
        let id: String; let name: String; let uri: String; let revision: String?
        let license: License; let files: [File]; let status: String
    }
    struct License: Decodable {
        let spdxId: String?; let commercialUse: String; let redistribution: String; let evidenceUri: String?
    }
    struct Context: Decodable {
        let id: String; let rules: Rules; let seats: [Seat]?; let street: String; let board: [Int]?
        let actionPath: [Action]?; let potBb: Double?; let stackBbByPlayer: [String: Double?]?
    }
    struct Rules: Decodable {
        let variant: String; let format: String?; let playersDealt: Int?
        let blinds: Blinds; let ante: Ante; let rake: Rake; let payouts: [Double]?
    }
    struct Blinds: Decodable { let smallBb: Double?; let bigBb: Double? }
    struct Ante: Decodable { let mode: String?; let amountBb: Double? }
    struct Rake: Decodable { let percent: Double?; let capBb: Double?; let noFlopNoDrop: Bool? }
    struct Seat: Decodable { let playerId: String; let seat: Int; let position: String?; let startingStackBb: Double? }
    struct Action: Decodable {
        let playerId: String; let street: String; let kind: String; let amountBb: Double?; let amountMeaning: String?
    }
    struct Definition: Decodable {
        let id: String; let kind: String; let label: String; let amountBb: Double?; let amountMeaning: String?
    }
    struct Node: Decodable {
        let id: String; let contextId: String; let playerId: String; let sourceId: String
        let evidence: Evidence; let actionDefinitions: [Definition]; let actionPolicy: Policy?; let reachRange: Reach?; let quality: Quality
    }
    struct Evidence: Decodable { let sourceFile: String; let sourceRecord: String?; let derivation: [String] }
    struct Policy: Decodable { let semantics: String; let byAction: [String: [Double?]] }
    struct Reach: Decodable { let semantics: String; let weights: [Double?]; let derivation: [String] }
    struct Quality: Decodable { let origin: String; let reviewStatus: String }
    struct Link: Decodable { let fromNodeId: String; let actionId: String; let toNodeId: String; let evidence: Evidence }
}

/// App-release-owned allowlist, never taken from an imported pack's own approval claims.
/// All referenced files are pinned by hash. No release index is currently shipped.
struct RangeCatalogReleaseIndex: Decodable {
    let schemaVersion: Int
    let releases: [Release]
    struct Release: Decodable {
        let packageId: String
        let packageVersion: String
        let path: String
        let sha256: String
        let reviewId: String
        let reviewer: String
        let reviewedAt: String
        let reviewEvidence: RangeCatalogPack.File
        let rangeNodeIds: [String]
        let actionLinks: [ApprovedLink]
        let quickAdjustmentPacks: [RangeQuickAdjustmentRelease]?
    }
    struct ApprovedLink: Decodable, Hashable {
        let fromNodeId: String
        let actionId: String
        let toNodeId: String
    }
}

struct RangeCatalogReference: Codable, Equatable, Sendable {
    let packageId: String
    let packageVersion: String
    let nodeId: String
    let contentHash: String
    let reviewId: String
    var actionId: String? = nil
    var parentNodeId: String? = nil
    var parentWeightsHash: String? = nil
    var modelChangeID: UUID? = nil
    var isValid: Bool {
        !packageId.isEmpty && !nodeId.isEmpty && !reviewId.isEmpty &&
        packageVersion.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil &&
        contentHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
        (actionId == nil) == (parentNodeId == nil) && (actionId == nil) == (parentWeightsHash == nil) &&
        actionId != "" && parentNodeId != "" &&
        (parentWeightsHash == nil || parentWeightsHash!.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil) &&
        (actionId != nil || modelChangeID == nil)
    }
}

struct RangeCatalogMatch {
    let reference: RangeCatalogReference
    let sourceName: String
    let sourceURI: String
    let sourceRevision: String
    let origin: String
    let conditions: String
    /// Reference weights stay immutable; blockers are applied separately by the workspace.
    let weights: [Double?]
}
struct RangeCatalogMatchStatus {
    let matches: [RangeCatalogMatch]
    let missing: [String]
    let mismatches: [String]
    let installationIssues: [String]
    var title: String {
        if !missing.isEmpty { return "待匹配 · 条件缺项" }
        if matches.count > 1 { return "多个审核参考 · 请明确选择" }
        if matches.count == 1 { return "已匹配审核参考" }
        return "待匹配 · 未覆盖"
    }
}

enum RangeCatalogError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let value) = self { return value }; return nil }
}
