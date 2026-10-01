import AppKit
import DualTrackRecorder
import Speech
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var devices: [AudioInputDevice] = []
    @State private var directoryError: String?
    @State private var microphoneError: String?
    @State private var templateEditor: SummaryTemplateEditorState?
    @State private var templateError: String?

    var body: some View {
        TabView {
            general.tabItem { Label("一般", systemImage: "gearshape") }
            recording.tabItem { Label("録音", systemImage: "mic") }
            transcription.tabItem { Label("文字起こし", systemImage: "text.bubble") }
            summary.tabItem { Label("要約", systemImage: "doc.text") }
        }
        .padding(20)
        .frame(width: 560, height: 340)
        .task {
            let recorder = DualTrackRecorder()
            do {
                devices = try await recorder.microphoneInputDevices()
                microphoneError = nil
                for await values in await recorder.microphoneInputDeviceChanges() {
                    if Task.isCancelled {
                        break
                    }
                    devices = values
                    microphoneError = nil
                }
            } catch {
                microphoneError = error.localizedDescription
            }
        }
    }

    private var general: some View {
        Form {
            LabeledContent("録音の保存先") {
                Text(directoryPath).textSelection(.enabled).lineLimit(3)
            }
            HStack {
                Button("フォルダを選択…", action: chooseDirectory)
                Button("既定に戻す") {
                    settings.resetOutputDirectory()
                    directoryError = nil
                }
            }
            Text("変更は次の録音から反映されます。既存ファイルは移動せず、ライブラリには現在の保存先のみを表示します。")
                .font(.callout).foregroundStyle(.secondary)
            if let availableSpace {
                LabeledContent("空き容量", value: availableSpace)
            }
            if let directoryError {
                Text(directoryError).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private var recording: some View {
        Form {
            Toggle("既定でシステム音声を録音", isOn: $settings.preferences.systemAudioEnabled)
            Toggle("既定でマイクを録音", isOn: $settings.preferences.microphoneEnabled)
            Picker("既定のマイク", selection: $settings.preferences.microphoneDeviceUID) {
                Text("システムの既定").tag(nil as String?)
                ForEach(devices.filter { $0.persistentUID != nil }) { device in
                    Text(device.displayName).tag(device.persistentUID)
                }
                if let uid = settings.preferences.microphoneDeviceUID,
                   !devices.contains(where: { $0.persistentUID == uid }) {
                    Text("未接続のマイク").tag(Optional(uid))
                }
            }
            Text("録音中の変更は終了後に反映されます。未接続のマイクはシステムの既定に戻ります。")
                .font(.callout).foregroundStyle(.secondary)
            if let microphoneError {
                Text("マイクの一覧を読み込めませんでした: \(microphoneError)")
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private var transcription: some View {
        Form {
            Picker("文字起こしの言語", selection: $settings.preferences.localeIdentifier) {
                ForEach(localeIdentifiers, id: \.self) { identifier in
                    Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
                }
            }
            Text("次に開始する文字起こしから適用されます。")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var summary: some View {
        Form {
            Picker("既定のテンプレート", selection: $settings.preferences.summaryTemplateID) {
                ForEach(settings.summaryTemplates) { template in
                    Text(template.name).tag(template.id)
                }
            }
            List(settings.summaryTemplates) { template in
                HStack {
                    VStack(alignment: .leading) {
                        Text(template.name)
                        Text(template.isBuiltIn ? "組み込み・読み取り専用" : "ユーザー定義")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("複製") { duplicate(template) }
                    Button("編集") { templateEditor = SummaryTemplateEditorState(template: template) }
                        .disabled(template.isBuiltIn)
                    Button("削除", role: .destructive) { delete(template) }
                        .disabled(template.isBuiltIn)
                }
            }
            .frame(height: 125)
            Button("テンプレートを追加") {
                templateEditor = SummaryTemplateEditorState(template: SummaryTemplate(
                    name: "新しいテンプレート",
                    instructions: SummaryTemplate.builtIn.instructions,
                    outputPerspective: SummaryTemplate.builtIn.outputPerspective
                ))
            }
            if let templateError {
                Text(templateError).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $templateEditor) { editor in
            SummaryTemplateEditor(template: editor.template) { template in
                do {
                    try settings.saveSummaryTemplate(template)
                    templateError = nil
                    templateEditor = nil
                } catch {
                    templateError = error.localizedDescription
                }
            }
        }
    }

    private func duplicate(_ template: SummaryTemplate) {
        do {
            let copy = try settings.duplicateSummaryTemplate(template)
            settings.preferences.summaryTemplateID = copy.id
            templateError = nil
        } catch {
            templateError = error.localizedDescription
        }
    }

    private func delete(_ template: SummaryTemplate) {
        do {
            try settings.deleteSummaryTemplate(id: template.id)
            templateError = nil
        } catch {
            templateError = error.localizedDescription
        }
    }

    private var directoryPath: String {
        do {
            return try settings.resolveOutputDirectory().path
        } catch {
            return error.localizedDescription
        }
    }

    private var availableSpace: String? {
        guard let url = try? settings.resolveOutputDirectory(),
              let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
    }

    private var localeIdentifiers: [String] {
        Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
            .union([settings.preferences.localeIdentifier, "ja-JP"])
            .sorted()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try settings.selectOutputDirectory(url)
            directoryError = nil
        } catch {
            directoryError = error.localizedDescription
        }
    }
}

private struct SummaryTemplateEditorState: Identifiable {
    let template: SummaryTemplate
    var id: String { template.id }
}

private struct SummaryTemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var template: SummaryTemplate
    let save: (SummaryTemplate) -> Void

    init(template: SummaryTemplate, save: @escaping (SummaryTemplate) -> Void) {
        _template = State(initialValue: template)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("要約テンプレート").font(.title2)
            TextField("名前", text: $template.name)
            Text("Instructions").font(.headline)
            TextEditor(text: $template.instructions).frame(height: 100)
            Text("出力観点").font(.headline)
            TextEditor(text: $template.outputPerspective).frame(height: 100)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") { save(template) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520, height: 390)
    }
}
