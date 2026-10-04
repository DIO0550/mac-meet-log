import SwiftUI

struct LibraryManagementActions: View {
    @ObservedObject var viewModel: LibraryViewModel
    var body: some View {
        HStack {
            Button("会議名・タグを編集", action: viewModel.beginMetadataEditing)
            Menu {
                ForEach(LibraryTrashScope.allCases) { scope in
                    Button(scope.title, role: .destructive) { viewModel.prepareTrash(scope) }
                }
            } label: { Label("ゴミ箱へ移動", systemImage: "trash") }
            if let item = viewModel.selectedItem, !item.tags.isEmpty {
                Text(item.tags.joined(separator: " · ")).foregroundStyle(.secondary)
            }
        }
    }
}

struct LibraryMetadataEditor: View {
    let item: RecordingLibraryItem
    let save: (String, [String]) -> Void
    let cancel: () -> Void
    let message: String?
    @State private var name = ""
    @State private var tags = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("会議名・タグを編集").font(.title2.bold())
            TextField("会議名", text: $name)
            TextField("タグ（カンマ区切り）", text: $tags)
            Text("保存ファイル名は変更されません。会議名を空にすると元の名前で表示します。")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("キャンセル", action: cancel)
                Button("保存") {
                    save(name, tags.components(separatedBy: CharacterSet(charactersIn: ",、\n")))
                }.keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24).frame(width: 480)
        .onAppear { name = item.title; tags = item.tags.joined(separator: ", ") }
    }
}

struct LibraryTrashConfirmation: View {
    let plan: LibraryTrashPlan
    let confirm: () -> Void
    let cancel: () -> Void
    let message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(plan.scope.title)をゴミ箱へ移動").font(.title2.bold())
            Text(plan.item.title).font(.headline)
            Text(plan.scope.explanation)
            Text("対象: \(plan.files.count) ファイル / \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.files) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.url.lastPathComponent).font(.body.monospaced())
                            Text("\(file.url.deletingLastPathComponent().path) · \(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 280)
            if let message { Text(message).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("キャンセル", action: cancel)
                Button("ゴミ箱へ移動", role: .destructive, action: confirm)
            }
        }.padding(24).frame(width: 600)
    }
}
