import SwiftUI

struct NodeNoteScreen: View {
    let handID: UUID
    let event: HandEvent
    @ObservedObject var store: LocalStore
    @State private var text = ""
    @State private var bookmarked = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("\(event.street.label) · \(event.kind.label)") {
                    Toggle("待复盘书签", isOn: $bookmarked)
                    TextEditor(text: $text).frame(minHeight: 180)
                }
                Section { Text("记录问题、自己的判断与复盘心得。笔记与这个节点绑定，删除原行动也会保留。") }
            }.scrollContentBackground(.hidden).background(HandStyle.canvas)
                .navigationTitle("节点笔记").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        do {
                            var note = store.nodeAnnotations.first { $0.handID == handID && $0.eventID == event.id } ?? NodeAnnotation(handID: handID, eventID: event.id)
                            note.text = text; note.isBookmarked = bookmarked
                            try store.upsertAnnotation(note); dismiss()
                        } catch { self.error = error.localizedDescription }
                    } }
                }
                .onAppear {
                    if let note = store.nodeAnnotations.first(where: { $0.handID == handID && $0.eventID == event.id }) { text = note.text; bookmarked = note.isBookmarked }
                }
                .alert("未保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("知道了") {} } message: { Text(error ?? "") }
        }
    }
}
