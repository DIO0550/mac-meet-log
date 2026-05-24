# Audio Import Implementation Plan

## 設計方針

Issue #4 Audio Import では、既存の mp3 / m4a / wav 音声ファイルを macOS アプリへ投入し、後続の Apple 公式 API ベースの処理へ渡せる入力として扱えるようにする。

設計は app target 内の `Features/AudioImport` に閉じる。`DualTrackRecorder` は録音 core framework のまま維持し、外部音声ファイルの選択、検証、メタ情報抽出、UI 状態管理は SwiftUI app 側の責務にする。

採用する構成:

- `AudioImportItem`: 後続 pipeline に渡す URL とメタ情報の値型。
- `AudioImportError`: UI で説明可能な typed import error。
- `AudioFileImporting`: async importer protocol。AVFoundation 依存を境界化する。
- `AVAudioFileImporter`: `AVAudioFile(forReading:)` を主経路にした実ファイル検証。
- `AudioImportViewModel`: `fileImporter` の選択結果を受け、loading / success / failure を管理する `@MainActor` view model。
- `LibraryView`: Library header に Import Audio の導線と結果表示を追加する。

この方針により、ファイル全体をメモリへ読み込まず、UI をブロックしない async 経路で import できる。AVFoundation と security-scoped access の扱いは importer に閉じ込め、view model と UI は fake importer で単体テスト可能にする。

## システム図

### 状態マシン図

```
                              User opens Library
                                      │
                                      ▼
                            ┌──────────────────┐
                            │ IDLE             │
                            │ no active import │
                            └────────┬─────────┘
                                     │ Import button tapped
                                     ▼
                            ┌──────────────────┐
                            │ PICKER_PRESENTED │
                            │ fileImporter UI  │
                            └─────┬──────┬─────┘
                                  │      │
                    user cancels  │      │ file URL selected
                                  │      ▼
                                  │ ┌──────────────────┐
                                  │ │ SECURITY_ACCESS  │
                                  │ │ start scope if   │
                                  │ │ available        │
                                  │ └─────┬──────┬─────┘
                                  │       │      │
                                  │       │      │ scope denied / URL unavailable
                                  │       │      ▼
                                  │       │ ┌──────────────────┐
                                  │       │ │ FAILED           │
                                  │       │ │ permission error │
                                  │       │ └────────┬─────────┘
                                  │       │          │ retry / dismiss
                                  │       ▼          │
                                  │ ┌──────────────────┐
                                  │ │ VALIDATING       │
                                  │ │ extension, size, │
                                  │ │ AVAudioFile read │
                                  │ └─────┬──────┬─────┘
                                  │       │      │
                                  │       │      │ unsupported / 0 byte /
                                  │       │      │ unreadable / no duration
                                  │       │      ▼
                                  │       │ ┌──────────────────┐
                                  │       │ │ FAILED           │
                                  │       │ │ typed import err │
                                  │       │ └────────┬─────────┘
                                  │       │          │ retry / dismiss
                                  │       ▼          │
                                  │ ┌──────────────────┐
                                  │ │ IMPORTED         │
                                  │ │ item ready for   │
                                  │ │ next pipeline    │
                                  │ └────────┬─────────┘
                                  │          │ retry import / clear
                                  └──────────┴───────────────▶ IDLE
```

### データフロー図

```
┌─────────────────────┐
│ LibraryView          │
│ Import Audio button  │
└──────────┬──────────┘
           │ toggles isImporterPresented
           ▼
┌─────────────────────┐
│ SwiftUI fileImporter │
│ allowed UTTypes      │
│ mp3 / m4a / wav      │
└──────────┬──────────┘
           │ Result<URL, Error>
           ▼
┌────────────────────────┐
│ AudioImportViewModel    │
│ @MainActor UI state     │
│ idle/importing/imported │
│ failed                  │
└──────────┬─────────────┘
           │ await importer.importAudio(from:)
           ▼
┌────────────────────────┐
│ AVAudioFileImporter     │
│ - security scope        │
│ - extension validation  │
│ - resourceValues size   │
│ - AVAudioFile reading   │
│ - duration calculation  │
└──────┬─────────────┬───┘
       │             │
       │ success     │ typed failure
       ▼             ▼
┌────────────────┐  ┌────────────────────┐
│ AudioImportItem │  │ AudioImportError    │
│ url/name/type   │  │ unsupportedFormat   │
│ size/duration   │  │ emptyFile           │
│ format summary  │  │ permissionDenied    │
└───────┬────────┘  │ unreadable          │
        │           │ metadataUnavailable │
        │           └──────────┬─────────┘
        ▼                      ▼
┌──────────────────────┐  ┌──────────────────────┐
│ Future Apple pipeline │  │ LibraryView alert /   │
│ Speech/Foundation     │  │ inline status text    │
│ Models issues         │  └──────────────────────┘
└──────────────────────┘
```

## フォルダ構造

### 現在実装済み

```
meet-log/
├── meet-log/
│   ├── App/
│   │   ├── AppRootView.swift
│   │   └── meet_logApp.swift
│   ├── Features/
│   │   ├── Recorder/
│   │   └── Library/
│   │       ├── LibraryView.swift
│   │       ├── LibraryViewModel.swift
│   │       ├── RecordingLibraryItem.swift
│   │       └── RecordingLibraryStore.swift
│   └── Support/
│       ├── AppCommands.swift
│       └── LibraryFileActions.swift
├── DualTrackRecorder/
│   └── Sources/
└── meet-logTests/
    └── RecordingLibraryTests.swift
```

### 実装後の構造

```
meet-log/
├── meet-log/
│   ├── App/
│   ├── Features/
│   │   ├── Recorder/
│   │   ├── Library/
│   │   │   └── LibraryView.swift          # Import 導線を追加
│   │   └── AudioImport/
│   │       ├── AudioImportItem.swift      # [NEW]
│   │       ├── AudioImportError.swift     # [NEW]
│   │       ├── AudioFileImporter.swift    # [NEW]
│   │       └── AudioImportViewModel.swift # [NEW]
│   └── Support/
├── DualTrackRecorder/
│   └── Sources/
└── meet-logTests/
    ├── RecordingLibraryTests.swift
    └── AudioImportTests.swift             # [NEW]
```

## 主要コンポーネントの設計

### [NEW] `AudioImportItem.swift`

型定義、import 文、後続 pipeline に渡すメタ情報を追加する。

```swift
import Foundation

struct AudioImportItem: Equatable, Sendable, Identifiable {
    let id: UUID
    let url: URL
    let fileName: String
    let fileExtension: String
    let byteSize: Int64
    let duration: Duration
    let channelCount: Int
    let sampleRate: Double

    init(
        id: UUID = UUID(),
        url: URL,
        fileName: String,
        fileExtension: String,
        byteSize: Int64,
        duration: Duration,
        channelCount: Int,
        sampleRate: Double
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.byteSize = byteSize
        self.duration = duration
        self.channelCount = channelCount
        self.sampleRate = sampleRate
    }
}
```

### [NEW] `AudioImportError.swift`

UI で説明可能な粒度の typed error を追加する。`LocalizedError` を実装し、SwiftUI は `localizedDescription` または `errorDescription` を表示できる。

```swift
import Foundation

enum AudioImportError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFormat(String)
    case fileNotFound
    case emptyFile
    case permissionDenied(String)
    case unreadable(String)
    case metadataUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(fileExtension):
            "Unsupported audio format: .\(fileExtension). Choose an mp3, m4a, or wav file."
        case .fileNotFound:
            "The selected audio file could not be found."
        case .emptyFile:
            "The selected audio file is empty."
        case let .permissionDenied(message):
            "The selected audio file could not be accessed: \(message)"
        case let .unreadable(message):
            "The selected audio file could not be read: \(message)"
        case let .metadataUnavailable(message):
            "Audio metadata could not be read: \(message)"
        }
    }
}
```

### [NEW] `AudioFileImporter.swift`

`AVAudioFile` 依存を小さな service に閉じ込める。ファイル全体を `Data` として読み込まず、resource values と `AVAudioFile` の metadata だけを読む。

```swift
import AVFoundation
import Foundation

protocol AudioFileImporting: Sendable {
    func importAudio(from url: URL) async throws -> AudioImportItem
}

struct AVAudioFileImporter: AudioFileImporting {
    private let supportedExtensions: Set<String>

    init(supportedExtensions: Set<String> = ["mp3", "m4a", "wav"]) {
        self.supportedExtensions = supportedExtensions
    }

    func importAudio(from url: URL) async throws -> AudioImportItem {
        try await Task.detached(priority: .userInitiated) {
            try importAudioSynchronously(from: url, supportedExtensions: supportedExtensions)
        }.value
    }
}

private func importAudioSynchronously(
    from url: URL,
    supportedExtensions: Set<String>
) throws -> AudioImportItem {
    let fileExtension = url.pathExtension.lowercased()
    guard supportedExtensions.contains(fileExtension) else {
        throw AudioImportError.unsupportedFormat(fileExtension)
    }

    let didStartAccessing = url.startAccessingSecurityScopedResource()
    defer {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }

    guard FileManager.default.fileExists(atPath: url.path) else {
        throw AudioImportError.fileNotFound
    }

    let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
    let byteSize = Int64(resourceValues.fileSize ?? 0)
    guard byteSize > 0 else {
        throw AudioImportError.emptyFile
    }

    let audioFile: AVAudioFile
    do {
        audioFile = try AVAudioFile(forReading: url)
    } catch {
        throw AudioImportError.unreadable(error.localizedDescription)
    }

    let sampleRate = audioFile.fileFormat.sampleRate
    guard sampleRate.isFinite, sampleRate > 0, audioFile.length > 0 else {
        throw AudioImportError.metadataUnavailable("Duration is unavailable.")
    }

    let seconds = Double(audioFile.length) / sampleRate
    let duration = Duration.seconds(Int64(seconds.rounded(.down)))
        + .nanoseconds(Int64((seconds.truncatingRemainder(dividingBy: 1) * 1_000_000_000).rounded()))

    return AudioImportItem(
        url: url,
        fileName: url.lastPathComponent,
        fileExtension: fileExtension,
        byteSize: byteSize,
        duration: duration,
        channelCount: Int(audioFile.fileFormat.channelCount),
        sampleRate: sampleRate
    )
}
```

### [NEW] `AudioImportViewModel.swift`

UI 状態を `@MainActor` に集約する。`fileImporter` の `Result<URL, Error>` はここで受け取り、importer の typed error に変換して表示状態を更新する。

```swift
import Foundation

@MainActor
final class AudioImportViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case importing
        case imported(AudioImportItem)
        case failed(AudioImportError)
    }

    @Published private(set) var state: State = .idle
    @Published var isImporterPresented = false

    private let importer: AudioFileImporting

    init(importer: AudioFileImporting = AVAudioFileImporter()) {
        self.importer = importer
    }

    func presentImporter() {
        isImporterPresented = true
    }

    func handleImporterResult(_ result: Result<URL, Error>) {
        isImporterPresented = false

        switch result {
        case let .success(url):
            importAudio(from: url)
        case .failure:
            state = .idle
        }
    }

    func clear() {
        state = .idle
    }

    private func importAudio(from url: URL) {
        state = .importing

        Task {
            do {
                state = .imported(try await importer.importAudio(from: url))
            } catch let error as AudioImportError {
                state = .failed(error)
            } catch {
                state = .failed(.unreadable(error.localizedDescription))
            }
        }
    }
}
```

### [MODIFY] `LibraryView.swift`

Library header に import button と `fileImporter` を追加する。詳細な配置は既存 `Refresh` button の近くに置く。

Before:

```swift
Button(action: viewModel.refresh) {
    Label("Refresh", systemImage: "arrow.clockwise")
}
.buttonStyle(.bordered)
```

After:

```swift
Button(action: audioImportViewModel.presentImporter) {
    Label("Import Audio", systemImage: "square.and.arrow.down")
}
.buttonStyle(.borderedProminent)

Button(action: viewModel.refresh) {
    Label("Refresh", systemImage: "arrow.clockwise")
}
.buttonStyle(.bordered)
.fileImporter(
    isPresented: $audioImportViewModel.isImporterPresented,
    allowedContentTypes: [.mp3, .mpeg4Audio, .wav],
    allowsMultipleSelection: false
) { result in
    audioImportViewModel.handleImporterResult(result.map { urls in urls[0] })
}
```

`fileImporter` の result は SDK により `Result<[URL], Error>` になるため、空配列を避ける helper を用意してもよい。

```swift
private func firstSelectedURL(from urls: [URL]) -> Result<URL, Error> {
    guard let url = urls.first else {
        return .failure(CocoaError(.userCancelled))
    }

    return .success(url)
}
```

### [MODIFY] `LibraryView.swift` の import 状態表示

Import 結果は Library の主表示を邪魔しない小さな status として表示する。後続 pipeline が実装されるまでは、選択済み item が ready であることを示す。

Before:

```swift
if let errorMessage = viewModel.errorMessage {
    Text(errorMessage)
        .foregroundStyle(.red)
}
```

After:

```swift
if let errorMessage = viewModel.errorMessage {
    Text(errorMessage)
        .foregroundStyle(.red)
}

switch audioImportViewModel.state {
case .idle:
    EmptyView()
case .importing:
    ProgressView("Importing audio...")
case let .imported(item):
    Label("\(item.fileName) is ready for transcription.", systemImage: "checkmark.circle")
        .foregroundStyle(.green)
case let .failed(error):
    Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
}
```

### [NEW] `AudioImportTests.swift`

Swift Testing を使い、外部 mock library は使わない。

```swift
import Foundation
import Testing
@testable import meet_log

struct FakeAudioFileImporter: AudioFileImporting {
    let result: Result<AudioImportItem, Error>

    func importAudio(from url: URL) async throws -> AudioImportItem {
        try result.get()
    }
}
```

## テスト戦略分析

`test-design-patterns.md` はこの skill ディレクトリに存在しないため、探索レポートのテストインフラとテンプレートの判断基準から分類する。

### Data Transformation

対象:

- 拡張子の正規化と対応形式判定。
- byte size、file name、duration、sample rate、channel count から `AudioImportItem` を組み立てる処理。
- `AudioImportError` の分類と user-facing message。

方針:

- pure helper または importer 内の小さな関数として切り出せる処理を優先して単体テストする。
- `mp3`, `MP3`, `m4a`, `wav` は許可され、`aac`, `txt`, 空拡張子は `unsupportedFormat` になることを確認する。
- 0 byte は `emptyFile`、存在しない URL は `fileNotFound` になることを確認する。

### Async Operations

対象:

- `AudioFileImporting.importAudio(from:) async throws`
- `AudioImportViewModel.handleImporterResult(_:)`
- `AudioImportViewModel` の `idle -> importing -> imported/failed` 遷移。

方針:

- fake importer を使い、AVFoundation なしで view model の state transition をテストする。
- 成功時は `imported(AudioImportItem)` へ遷移する。
- typed error 時は同じ `AudioImportError` を保持して `failed` へ遷移する。
- unknown error 時は `.unreadable` に丸める。

### UI Component

対象:

- `LibraryView` の Import Audio button。
- `fileImporter` の allowed content types。
- import 状態の表示。

方針:

- SwiftUI の file picker 自体は E2E 自動化せず、手動確認にする。
- UI logic は `AudioImportViewModel` に寄せ、view の自動テスト負荷を下げる。
- 実装後の手動確認で mp3 / m4a / wav が選択でき、unsupported 拡張子が UI 上で説明されることを確認する。

### テスト TODO

- [ ] `AudioImportError` の localized message が主要ケースで空にならない。
- [ ] unsupported 拡張子が `.unsupportedFormat` に分類される。
- [ ] 0 byte file が `.emptyFile` に分類される。
- [ ] 存在しない URL が `.fileNotFound` に分類される。
- [ ] fake importer 成功時に view model state が `.imported` になる。
- [ ] fake importer typed error 時に view model state が `.failed` になる。
- [ ] 実音声 fixture または一時生成した wav で `AVAudioFileImporter` が duration と metadata を返す。

## 利点

1. **責務境界が明確**: 外部 import は app feature に置き、録音 framework へ不要な UI / ファイル選択責務を持ち込まない。
2. **テストしやすい**: AVFoundation は `AVAudioFileImporter` に閉じ、view model は fake importer で async state を検証できる。
3. **後続 Issue と接続しやすい**: `AudioImportItem` は URL、duration、形式、サイズを持つため、Speech / Foundation Models pipeline の入力型として使える。
4. **ユーザーに説明しやすい失敗**: unsupported、permission、empty、unreadable、metadata unavailable を typed error として分離する。

## 使用例

```swift
let importer: AudioFileImporting = AVAudioFileImporter()
let item = try await importer.importAudio(from: selectedURL)

// Future pipeline
// try await transcriptionService.transcribeImportedAudio(item)
```

SwiftUI:

```swift
@StateObject private var audioImportViewModel = AudioImportViewModel()

Button(action: audioImportViewModel.presentImporter) {
    Label("Import Audio", systemImage: "square.and.arrow.down")
}
```

## 実装状態

### 実装済み

- Library feature
  - 録音済みファイルの scan、metadata 表示、refresh 導線。
  - `AVURLAsset` による duration provider。
- Recorder / DualTrackRecorder
  - 録音後の audio file 出力。
  - `RecorderError` による typed error pattern。
- Tests
  - Swift Testing による Library / file IO 系の既存テスト。

### 未実装

- `Features/AudioImport` domain / service / view model。
- `AVAudioFile` を使った外部音声 validation。
- mp3 / m4a / wav 選択用の `fileImporter` 導線。
- typed import error の UI 表示。
- `meet-logTests/AudioImportTests.swift`。

## 移行計画

### Phase 1: Red - domain と importer のテスト追加

- `AudioImportTests.swift` を追加する。
- 拡張子判定、0 byte、存在しない URL、view model state transition の失敗するテストを書く。
- 可能なら一時 wav fixture 生成 helper を追加し、`AVAudioFileImporter` の正常系テストも先に書く。

### Phase 2: Green - AudioImport core 実装

- `AudioImportItem.swift` を追加する。
- `AudioImportError.swift` を追加する。
- `AudioFileImporter.swift` を追加し、`AVAudioFile(forReading:)` を主検証経路にする。
- `AudioImportViewModel.swift` を追加する。
- Phase 1 のテストを通す。

### Phase 3: Red/Green - Library UI 統合

- `LibraryView.swift` に `@StateObject private var audioImportViewModel` を追加する。
- Header に Import Audio button を追加する。
- `fileImporter` を接続し、mp3 / m4a / wav の allowed content types を指定する。
- import 状態と error を表示する。

### Phase 4: Refactor - 境界と UX の整理

- `Result<[URL], Error>` から `URL` へ変換する helper を整理する。
- `AudioImportError` の文言を短く一貫したものにする。
- security-scoped access の挙動を sandbox / entitlement 設定に合わせて確認する。
- 後続 pipeline が期待する入力に対して `AudioImportItem` が過不足ないか確認する。

## 技術的な詳細

### エラーハンドリング

- 非対応拡張子: `AVAudioFile` を開く前に `.unsupportedFormat` を返す。
- 存在しないファイル: `FileManager.fileExists` で `.fileNotFound` を返す。
- 0 byte: resource values の `.fileSizeKey` から `.emptyFile` を返す。
- 権限 / security scope: access 開始や resource values 取得で失敗した場合は `.permissionDenied` または `.unreadable` に分類する。
- 破損 / AVFoundation で開けないファイル: `AVAudioFile(forReading:)` の throw を `.unreadable` に包む。
- duration / sample rate 不正: `.metadataUnavailable` を返す。

### パフォーマンス考慮

- ファイル全体を `Data(contentsOf:)` で読み込まない。
- `AVAudioFile(forReading:)` と resource values 取得は async importer 経由で実行する。
- UI state 更新は `@MainActor` view model に限定する。
- import 対象が大きくても、metadata extraction のみで後続 pipeline に URL を渡す。

### セキュリティ考慮

- `fileImporter` で得た URL は importer 内で `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` を対にして扱う。
- Issue #4 では永続化を必須にしない。将来、アプリ再起動後にも同じ外部ファイルへアクセスする要件が出た場合は bookmark data を別 Issue で設計する。

## Definition of Done

- [ ] Library 画面から mp3 / m4a / wav ファイルを選択できる。
- [ ] 選択された音声ファイルが `AVAudioFile(forReading:)` で検証される。
- [ ] import 成功時に URL、file name、extension、byte size、duration、channel count、sample rate を含む `AudioImportItem` が作られる。
- [ ] `AudioImportItem` を後続 Apple 公式 API pipeline に渡せる app 内状態として保持できる。
- [ ] 非対応拡張子が typed error として UI に説明される。
- [ ] 0 byte file が typed error として UI に説明される。
- [ ] 存在しない / アクセス不可ファイルが typed error として UI に説明される。
- [ ] 破損または AVFoundation で開けないファイルが typed error として UI に説明される。
- [ ] duration または metadata を取得できないファイルが typed error として UI に説明される。
- [ ] import 処理でファイル全体をメモリへ読み込まない。
- [ ] import 中に SwiftUI main thread を長時間ブロックしない async 経路になっている。
- [ ] `meet-logTests/AudioImportTests.swift` に Data Transformation / Async Operations のユニットテストが追加されている。
- [ ] `xcodebuild test -project meet-log/meet-log.xcodeproj -scheme meet-log` が成功する。
- [ ] 実機またはローカル macOS app で mp3 / m4a / wav の手動 import 確認が完了している。

## 参考資料

- `.plugin-workspace/.specs/002-audio-import/hearing-notes.md`
- `.plugin-workspace/.specs/002-audio-import/exploration-report.md`
- `Task/31-apple-official-transcription-availability.md`
- `meet-log/meet-log/Features/Library/RecordingLibraryStore.swift`
- `meet-log/DualTrackRecorder/Sources/RecorderError.swift`
