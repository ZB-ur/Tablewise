import Foundation
import CryptoKit

/// Only a release-owned Bundle index can activate catalogs in the shipping app.
/// Candidate folders, Documents imports and pack publication flags are never scanned.
struct RangeCatalogRepository {
    struct Installed {
        let pack: RangeCatalogPack
        let release: RangeCatalogReleaseIndex.Release
    }
    let installed: [Installed]
    let issues: [String]
    var quickAdjustments: [RangeQuickAdjustmentInstalled] = []
    static let bundled: Self = load(bundle: .main)

    static func load(bundle: Bundle) -> Self {
        guard let index = bundle.url(forResource: "range-catalog-release-index", withExtension: "json") else {
            return .init(installed: [], issues: ["尚无随应用发布的审核范围覆盖索引"])
        }
        do {
            let root = index.deletingLastPathComponent().resolvingSymlinksInPath()
            let data = try Data(contentsOf: index)
            return try loadReleaseIndex(data) { path in
                guard safePath(path) else { throw RangeCatalogError.invalid("不合法资源路径") }
                let url = root.appendingPathComponent(path).resolvingSymlinksInPath()
                guard url.path.hasPrefix(root.path + "/") else { throw RangeCatalogError.invalid("资源越出发布目录") }
                return try Data(contentsOf: url, options: .mappedIfSafe)
            }
        } catch { return .init(installed: [], issues: ["审核目录读取失败：\(error.localizedDescription)"]) }
    }

    /// The caller must supply a trusted app-release index, NOT a user-supplied approval document.
    /// Exposed separately to allow release tooling to validate exactly the runtime representation.
    static func loadReleaseIndex(_ data: Data, readResource: (String) throws -> Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw RangeCatalogError.invalid("发布索引过大") }
        let index = try JSONDecoder().decode(RangeCatalogReleaseIndex.self, from: data)
        guard [1, 2].contains(index.schemaVersion), index.releases.count <= 100 else { throw RangeCatalogError.invalid("发布索引版本或规模不支持") }
        var installed: [Installed] = [], issues: [String] = [], seen = Set<String>()
        var quick: [RangeQuickAdjustmentInstalled] = []
        for release in index.releases {
            let identity = release.packageId + "@" + release.packageVersion
            guard seen.insert(identity).inserted else { throw RangeCatalogError.invalid("重复包版本：\(identity)") }
            do {
                guard safePath(release.path), validHash(release.sha256), !release.reviewId.isEmpty, !release.reviewer.isEmpty,
                      ISO8601DateFormatter().date(from: release.reviewedAt) != nil,
                      safePath(release.reviewEvidence.path), validHash(release.reviewEvidence.sha256),
                      !release.rangeNodeIds.isEmpty, Set(release.rangeNodeIds).count == release.rangeNodeIds.count,
                      (release.quickAdjustmentPacks?.count ?? 0) <= 100,
                      Set(release.actionLinks).count == release.actionLinks.count else {
                    throw RangeCatalogError.invalid("人工审核、内容哈希或覆盖清单不完整")
                }
                let review = try readResource(release.reviewEvidence.path)
                guard !review.isEmpty, hash(review) == release.reviewEvidence.sha256 else { throw RangeCatalogError.invalid("审核证据哈希不符") }
                let raw = try readResource(release.path)
                guard raw.count <= 32 * 1_024 * 1_024, hash(raw) == release.sha256 else { throw RangeCatalogError.invalid("包内容哈希或大小不符") }
                let pack = try JSONDecoder().decode(RangeCatalogPack.self, from: raw)
                try validate(pack, release: release)
                let directory = (release.path as NSString).deletingLastPathComponent
                for source in pack.sources {
                    for file in source.files {
                        let path = directory.isEmpty ? file.path : directory + "/" + file.path
                        let evidence = try readResource(path)
                        guard hash(evidence) == file.sha256 else { throw RangeCatalogError.invalid("来源原文件哈希不符：\(file.path)") }
                    }
                }
                guard index.schemaVersion == 2 || release.quickAdjustmentPacks?.isEmpty != false else { throw RangeCatalogError.invalid("快捷操作发布清单需要索引 v2") }
                installed.append(.init(pack: pack, release: release))
                if let entries = release.quickAdjustmentPacks, !entries.isEmpty {
                    for entry in entries {
                        do {
                            guard !quick.contains(where: { $0.pack.id == entry.id && $0.pack.packageVersion == entry.packageVersion }) else { throw RangeCatalogError.invalid("重复快捷操作包版本") }
                            quick.append(try loadQuickAdjustment(entry, base: pack, release: release, readResource: readResource))
                        }
                        catch { issues.append("快捷操作 \(entry.id)：\(error.localizedDescription)") }
                    }
                }
            } catch { issues.append("\(identity)：\(error.localizedDescription)") }
        }
        var result = Self(installed: installed, issues: issues)
        result.quickAdjustments = quick
        return result
    }

    private static func validate(_ pack: RangeCatalogPack, release: RangeCatalogReleaseIndex.Release) throws {
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw RangeCatalogError.invalid(message) } }
        try require(pack.schemaVersion == "1.0.0" && pack.encoding.id == "holdem-1326-cdhs-v1", "不支持的格式或组合编码")
        try require(pack.id == release.packageId && pack.packageVersion == release.packageVersion &&
                    pack.packageVersion.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil, "包身份／版本不符")
        try require(pack.publication.status == "reviewed" && pack.publication.automaticMatchingAllowed && pack.publication.blockingReasons.isEmpty,
                    "包仍有发布阻塞；候选不能作为自动参考")
        try require(!pack.sources.isEmpty && !pack.contexts.isEmpty && !pack.nodes.isEmpty, "包缺少来源、局面或节点")
        try require(Set(pack.sources.map(\.id)).count == pack.sources.count && Set(pack.contexts.map(\.id)).count == pack.contexts.count && Set(pack.nodes.map(\.id)).count == pack.nodes.count, "来源／局面／节点 ID 重复")
        for source in pack.sources {
            try require(!source.id.isEmpty && !source.name.isEmpty && !source.uri.isEmpty && source.revision?.isEmpty == false && source.status == "verified", "来源版本或核验缺失")
            try require(source.license.commercialUse == "allowed" && source.license.redistribution == "allowed" && source.license.evidenceUri?.isEmpty == false, "商用或再分发资格未确认")
            try require(!source.files.isEmpty && Set(source.files.map(\.path)).count == source.files.count && source.files.allSatisfy { safePath($0.path) && validHash($0.sha256) }, "来源证据路径或哈希缺失")
        }
        for context in pack.contexts {
            try require(!context.id.isEmpty, "空局面 ID")
            if let board = context.board {
                try require(board.allSatisfy { (0..<52).contains($0) } && Set(board).count == board.count, "公共牌重复或编码无效")
                try require(board.count == ["preflop":0,"flop":3,"turn":4,"river":5][context.street], "街次与公共牌数量不符")
            }
        }
        for node in pack.nodes {
            try require(!node.id.isEmpty && pack.contexts.contains { $0.id == node.contextId }, "节点局面引用断裂")
            guard let source = pack.sources.first(where: { $0.id == node.sourceId }) else { throw RangeCatalogError.invalid("节点来源引用断裂") }
            try require(source.files.contains { $0.path == node.evidence.sourceFile }, "节点证据不在已核验来源中")
            try require(["imported","solver_generated","teaching"].contains(node.quality.origin), "来源类型无效")
            try require(Set(node.actionDefinitions.map(\.id)).count == node.actionDefinitions.count, "动作 ID 重复")
            if let range = node.reachRange { try require(range.semantics == "combo_inclusion_weight" && validWeights(range.weights), "到达范围语义或权重无效") }
            if let policy = node.actionPolicy {
                try require(policy.semantics == "conditional_action_probability" && !node.actionDefinitions.isEmpty && Set(policy.byAction.keys) == Set(node.actionDefinitions.map(\.id)), "行动概率与定义不一致")
                try require(policy.byAction.values.allSatisfy(validWeights), "行动概率数组无效")
                for index in 0..<1326 {
                    let values = policy.byAction.values.compactMap { $0[index] }
                    try require(values.isEmpty || (values.count == policy.byAction.count && abs(values.reduce(0,+) - 1) <= 1e-9), "行动概率不完整或总和不为 1")
                }
            }
        }
        for id in release.rangeNodeIds {
            guard let node = pack.nodes.first(where: { $0.id == id }), let context = pack.contexts.first(where: { $0.id == node.contextId }) else { throw RangeCatalogError.invalid("审核覆盖引用断裂") }
            try require(node.quality.reviewStatus == "reviewed", "节点未通过人工审核")
            let missing = RangeCatalogMatcher.contextMissing(context)
            try require(missing.isEmpty, "审核节点场景缺项：" + missing.joined(separator: "、"))
            try require(context.seats?.contains { $0.playerId == node.playerId } == true, "范围玩家未在局面座位中")
            try require(node.reachRange?.weights.allSatisfy { $0 != nil } == true && node.reachRange?.weights.contains { ($0 ?? 0) > 0 } == true, "审核范围未知或全零")
        }
        for link in release.actionLinks {
            guard let declared = pack.links.first(where: { $0.fromNodeId == link.fromNodeId && $0.toNodeId == link.toNodeId && $0.actionId == link.actionId }),
                  let from = pack.nodes.first(where: { $0.id == link.fromNodeId }), let to = pack.nodes.first(where: { $0.id == link.toNodeId }),
                  let source = pack.sources.first(where: { $0.id == from.sourceId }),
                  let before = pack.contexts.first(where: { $0.id == from.contextId }), let after = pack.contexts.first(where: { $0.id == to.contextId }) else { throw RangeCatalogError.invalid("审核行动连接引用断裂") }
            try require(release.rangeNodeIds.contains(from.id) && release.rangeNodeIds.contains(to.id) && from.playerId == to.playerId,
                        "更新两端必须覆盖同一玩家的审核节点")
            try require(source.files.contains { $0.path == declared.evidence.sourceFile } && !declared.evidence.derivation.isEmpty, "缺少同树行动连接证据")
            try require(from.actionPolicy?.byAction[link.actionId]?.allSatisfy { $0 != nil } == true,
                        "审核行动概率仍未知")
            try require(RangeCatalogMatcher.isImmediateLink(from: from, before: before, after: after, actionID: link.actionId), "行动连接不是精确的一步路径")
        }
    }
    static func safePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && !value.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }
    static func validHash(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validWeights(_ values: [Double?]) -> Bool { values.count == 1326 && values.allSatisfy { $0.map { $0.isFinite && (0...1).contains($0) } ?? true } }
}
