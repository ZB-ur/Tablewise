import SwiftUI
import UniformTypeIdentifiers

private struct TablewiseBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LocalStore
    var showsDoneButton = true
    var onDataReplaced: () -> Void = {}
    @State private var importing = false
    @State private var exporting = false
    @State private var document: TablewiseBackupDocument?
    @State private var preview: ImportPreview?
    @State private var confirmReplacement = false
    @State private var confirmEmptyRecovery = false
    @State private var status: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("显示偏好") {
                    Picker("金额单位", selection: preference(\.units)) {
                        Text("筹码").tag(StorePreferences.Units.chips)
                        Text("BB").tag(StorePreferences.Units.bigBlinds)
                    }
                    Picker("时间线总览", selection: preference(\.overviewMode)) {
                        Text("紧凑").tag(StorePreferences.OverviewMode.compact)
                        Text("展开").tag(StorePreferences.OverviewMode.expanded)
                    }
                    Toggle("回放时先隐藏分析", isOn: preference(\.hideAnalysis))
                }.disabled(store.requiresRecovery)
                Section {
                    LabeledContent("已保存牌局", value: "\(store.hands.count) 手")
                    LabeledContent("连续场次", value: "\(store.sessions.count) 场")
                    LabeledContent("范围方案", value: "\(store.rangePlans.count) 份")
                    Button { exportBackup(original: false) } label: { Label("导出完整备份", systemImage: "square.and.arrow.up") }
                        .disabled(store.requiresRecovery)
                    Button {
                        status = nil; error = nil; preview = nil; confirmReplacement = false
                        importing = true
                    } label: { Label("从备份恢复", systemImage: "square.and.arrow.down") }
                } header: { Text("本地数据") } footer: {
                    Text("备份包括场次、玩家及资金事件、牌局与结算、范围方案、节点标记和显示偏好。恢复会替换本机现有数据；请先导出当前备份。数据不会自动上传或跨设备同步。")
                }
                if store.requiresRecovery {
                    Section {
                        Text(store.saveError ?? "本地文件无法读取。原文件已保留，尚未覆盖。").foregroundStyle(HandStyle.red)
                        Button("导出原文件以便恢复") { exportBackup(original: true) }
                        Button("保留原文件并重建空数据", role: .destructive) { confirmEmptyRecovery = true }
                    } header: { Text("需要恢复") }
                }
                if let preview {
                    Section("待恢复备份") {
                        LabeledContent("牌局", value: "\(preview.handCount) 手")
                        LabeledContent("场次", value: "\(preview.sessionCount) 场")
                        LabeledContent("范围方案", value: "\(preview.rangePlanCount) 份")
                        LabeledContent("节点标记", value: "\(preview.annotationCount) 条")
                        ForEach(Array(preview.handTitles.prefix(5).enumerated()), id: \.offset) { _, title in Text(title).font(.subheadline) }
                        Text("将替换当前 \(store.hands.count) 手牌局及所有关联数据。").font(.footnote).foregroundStyle(HandStyle.red)
                        Button("确认替换本机数据", role: .destructive) { confirmReplacement = true }
                        Button("取消恢复") { self.preview = nil }
                    }
                }
                if let status { Section { Label(status, systemImage: "checkmark.circle").foregroundStyle(HandStyle.green) } }
                if let error { Section { Text(error).foregroundStyle(HandStyle.red) } }
                Section { Text("字体大小与减少动态效果沿用系统设置。").font(.footnote).foregroundStyle(HandStyle.muted) }
            }
            .scrollContentBackground(.hidden).background(HandStyle.canvas)
            .navigationTitle("我的").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                status = nil; error = nil; preview = nil; confirmReplacement = false
                do {
                    guard let url = try result.get().first else { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    preview = try store.previewImport(Data(contentsOf: url))
                } catch {
                    status = nil; preview = nil; confirmReplacement = false
                    self.error = "未能读取备份：\(error.localizedDescription)"
                }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Tablewise-backup") { result in
                switch result {
                case .success: status = "备份已导出。"; error = nil
                case .failure(let failure): status = nil; error = failure.localizedDescription
                }
            }
            .alert("替换本机全部数据？", isPresented: $confirmReplacement) {
                Button("取消", role: .cancel) {}
                Button("替换并恢复", role: .destructive) { restore() }
            } message: { Text("恢复完成后使用备份中的全部场次、资金事件、牌局、范围方案、标记和偏好，当前记录不会合并。") }
            .alert("重建空数据？", isPresented: $confirmEmptyRecovery) {
                Button("取消", role: .cancel) {}
                Button("保留原文件并重建", role: .destructive) {
                    do { try store.recoverWithEmptyStore(); status = "已重建本地数据，原文件已另存保留。"; error = nil; onDataReplaced() }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text("无法读取的原文件会先另存保留，再建立空白牌局库。") }
        }.tint(HandStyle.green)
    }
    private func preference<Value>(_ key: WritableKeyPath<StorePreferences, Value>) -> Binding<Value> {
        Binding(get: { store.preferences[keyPath: key] }, set: { value in
            var preferences = store.preferences; preferences[keyPath: key] = value
            if key == \StorePreferences.overviewMode { preferences.overviewModeChosen = true }
            do { try store.updatePreferences(preferences) } catch { self.error = error.localizedDescription }
        })
    }
    private func exportBackup(original: Bool) {
        status = nil; error = nil
        do {
            let data: Data
            if original { data = try store.originalFileData() }
            else { data = try store.exportData() }
            document = TablewiseBackupDocument(data: data)
            exporting = true; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func restore() {
        guard let preview else { return }
        do {
            if store.requiresRecovery { try store.recoverByReplacing(with: preview) }
            else { try store.replaceAll(with: preview) }
            self.preview = nil; status = "已恢复 \(store.hands.count) 手牌局。"; error = nil
            onDataReplaced()
        } catch { self.error = error.localizedDescription }
    }
}
