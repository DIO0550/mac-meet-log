import AppKit
import DualTrackRecorder
import Speech
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var devices: [AudioInputDevice] = []
    @State private var directoryError: String?
    @State private var microphoneError: String?
    @State private var showingTemplate = false

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
                Text("会議ログ（標準）").tag("meeting")
            }
            Button("テンプレートを表示…") { showingTemplate = true }
                .sheet(isPresented: $showingTemplate) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("会議ログ（標準）").font(.title2)
                        Text("要約、主要トピック、アクションアイテム（担当者・期限）を日本語で整理します。")
                        Text("標準テンプレートは読み取り専用です。")
                            .foregroundStyle(.secondary)
                        Button("閉じる") { showingTemplate = false }
                    }
                    .padding(24).frame(width: 420)
                }
        }
        .formStyle(.grouped)
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
