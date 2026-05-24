# Codebase Exploration Report: Audio Import

**探索目的**: Issue #4 の mp3 / m4a / wav 音声ファイル取り込みについて、既存 macOS app / DualTrackRecorder / Library の責務境界、再利用可能な AVFoundation とファイル IO パターン、テスト配置を確認する。

---

## 0. エグゼクティブサマリー

**重要な発見（Top 5）**:
1. 外部音声 import 専用のドメインはまだ存在しない。既存の音声ファイル処理は録音後の Library 表示/再生と DualTrackRecorder 内の出力処理に分かれている。
2. `DualTrackRecorder` は録音 core framework として SwiftUI 非依存で、外部ファイル投入は app target の `Features/AudioImport` に置くのが既存境界に合う。
3. `RecordingLibraryStore` は `AVURLAsset` で duration を読む既存パターンを持つが、Issue #4 の主検証は `AVAudioFile` を使うべきと `Task/31-apple-official-transcription-availability.md` に明記されている。
4. UI は `AppRootView` で Recorder / Library を切り替える単純構成。Audio Import の導線は Library header または新しい destination として追加しやすい。
5. テストは Swift Testing を使い、`meet-logTests` と `DualTrackRecorderTests` に分かれる。AudioImport は app feature のため `meet-logTests/AudioImportTests.swift` が自然。

**推奨される次のステップ**:
- `AudioImportItem`, `AudioImportError`, `AudioFileImporting` を app target に追加し、`AVAudioFile` 依存を小さな importer に閉じ込める。
- SwiftUI の `fileImporter` で mp3 / m4a / wav を選択し、import 結果を Library か専用 import view model に表示する。

---

## 1. アーキテクチャ概要

### 1.1 ディレクトリ構造

```
meet-log/
  meet-log.xcodeproj/
  meet-log/
    App/
      AppRootView.swift
      meet_logApp.swift
    Features/
      Recorder/
      Library/
    Support/
      AppCommands.swift
      LibraryFileActions.swift
  DualTrackRecorder/
    Sources/
      Capture/
      FileIO/
      Mixdown/
      Session/
      RecorderError.swift
      RecordingResult.swift
  meet-logTests/
  DualTrackRecorderTests/
Task/
  31-apple-official-transcription-availability.md
```

**構造の特徴**:
- app target は SwiftUI の画面/状態管理と Library のファイル表示を担当する。
- `DualTrackRecorder` framework は録音 core として `Foundation / CoreAudio / AVFoundation` を扱い、SwiftUI を import しない。
- Xcode project は file system synchronized groups を使っているため、新規 Swift ファイル追加時の pbxproj 手編集は不要な可能性が高い。

### 1.2 主要ファイル

| ファイルパス | 役割 | 重要度 |
|-------------|------|--------|
| `meet-log/meet-log/App/AppRootView.swift` | Recorder / Library destination を切り替える root UI | 高 |
| `meet-log/meet-log/Features/Library/LibraryView.swift` | Library header / list / detail UI、導線追加候補 | 高 |
| `meet-log/meet-log/Features/Library/LibraryViewModel.swift` | Library の async load と selection 管理 | 中 |
| `meet-log/meet-log/Features/Library/RecordingLibraryStore.swift` | 出力フォルダ scan と `AVURLAsset` duration provider | 高 |
| `meet-log/meet-log/Support/LibraryFileActions.swift` | Finder reveal と `AVAudioPlayer` playback | 中 |
| `meet-log/DualTrackRecorder/Sources/RecorderError.swift` | 既存 typed error パターン | 中 |
| `Task/31-apple-official-transcription-availability.md` | #4 の実装境界: `AVAudioFile` validation + typed errors | 高 |

### 1.3 レイヤー構成

```
SwiftUI App
  ├─ AppRootView
  ├─ Features/Recorder  ──▶ DualTrackRecorder.framework
  ├─ Features/Library   ──▶ AVFoundation metadata/playback
  └─ Features/AudioImport (new) ──▶ AVFoundation file validation

DualTrackRecorder.framework
  ├─ Session / Capture
  ├─ FileIO / Mixdown
  └─ public recording API
```

**各層の責務**:
- App layer: ユーザー導線、ファイル選択、結果表示、後続パイプラインへの入力管理。
- AudioImport feature: URL の検証、メタ情報抽出、import error 分類。
- DualTrackRecorder: 録音と録音結果生成。外部ファイル import とは独立。

### 1.4 依存関係

```
LibraryView
  └─ LibraryViewModel
       └─ RecordingLibraryStoring
            ├─ OutputDirectoryRecordingLibraryStore
            └─ FakeRecordingLibraryStore

Proposed:
LibraryView or AudioImportView
  └─ AudioImportViewModel
       └─ AudioFileImporting
            ├─ AVAudioFileImporter
            └─ FakeAudioFileImporter
```

**循環依存**: 現状なし。AudioImport も app target 内に閉じれば `DualTrackRecorder` への逆依存は発生しない。
**主要な外部依存**: SwiftUI, AppKit, AVFoundation, Swift Testing。

---

## 2. 関連コード分析

### 2.1 変更対象に関連する既存コード

| ファイルパス | 関連内容 | 関連度 |
|-------------|---------|--------|
| `meet-log/meet-log/Features/Library/LibraryView.swift` | Header に action button があり、import ボタン追加候補 | 高 |
| `meet-log/meet-log/Features/Library/LibraryViewModel.swift` | async refresh/state パターン、error text 表示 | 中 |
| `meet-log/meet-log/Features/Library/RecordingLibraryStore.swift` | FileManager scan と AVFoundation duration provider | 高 |
| `meet-log/meet-log/Features/Library/RecordingLibraryItem.swift` | 音声 item の metadata 表示パターン | 中 |
| `meet-log/meet-log/Support/LibraryFileActions.swift` | `AVAudioPlayer(contentsOf:)` で再生可能性を扱う | 中 |
| `meet-log/DualTrackRecorder/Sources/FileIO/TrackFileWriter.swift` | `AVAudioFile` エラーを typed error へ包む既存方針 | 中 |
| `meet-log/meet-logTests/RecordingLibraryTests.swift` | Swift Testing + fake provider + temp directory のテストパターン | 高 |

### 2.2 再利用可能なパターン

#### パターン: async store / fake dependency

**場所**: `meet-log/meet-log/Features/Library/RecordingLibraryStore.swift`
**概要**: protocol で async store を抽象化し、fake 実装で view model tests を書ける。
**再利用方法**: `AudioFileImporting` protocol と `FakeAudioFileImporter` を作り、`AudioImportViewModel` を AVFoundation なしでテストする。

```swift
protocol RecordingLibraryStoring: Sendable {
    func recordings() async throws -> [RecordingLibraryItem]
}

struct FakeRecordingLibraryStore: RecordingLibraryStoring {
    var result: Result<[RecordingLibraryItem], Error>

    func recordings() async throws -> [RecordingLibraryItem] {
        try result.get()
    }
}
```

#### パターン: AVFoundation metadata provider

**場所**: `meet-log/meet-log/Features/Library/RecordingLibraryStore.swift`
**概要**: AVFoundation 依存を provider に閉じ込め、duration を optional で返す。
**再利用方法**: import では `AVAudioFile` で frame count / sample rate から duration を計算し、取得失敗は `AudioImportError.unreadable` に分類する。

```swift
struct AVRecordingDurationProvider: RecordingDurationProviding {
    func duration(for url: URL) -> Duration? {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else {
            return nil
        }
        return .seconds(Int64(seconds.rounded(.down)))
            + .nanoseconds(Int64((seconds.truncatingRemainder(dividingBy: 1) * 1_000_000_000).rounded()))
    }
}
```

#### パターン: user-facing typed error

**場所**: `meet-log/DualTrackRecorder/Sources/RecorderError.swift`
**概要**: enum が `LocalizedError` を実装し、UI は `localizedDescription` で表示できる。
**再利用方法**: `AudioImportError` も `Equatable, LocalizedError, Sendable` として定義し、unsupported / permissionDenied / unreadable / metadataUnavailable を分ける。

```swift
public enum RecorderError: Error, Equatable, LocalizedError, Sendable {
    case permissionDenied(String)
    case captureFailed(String)
    case outputFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .permissionDenied(message),
             let .captureFailed(message),
             let .outputFailed(message):
            message
        }
    }
}
```

#### パターン: `AVAudioFile` construction error wrapping

**場所**: `meet-log/DualTrackRecorder/Sources/FileIO/TrackFileWriter.swift`
**概要**: AVFoundation の throwing API を呼び、既存 typed error へ包む。
**再利用方法**: `try AVAudioFile(forReading: url)` を import validator の中心にし、失敗時の前段チェック結果と組み合わせて原因を分類する。

```swift
private func makeAudioFile(for format: AVAudioFormat) throws -> AVAudioFile {
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        audioFile = file
        return file
    } catch {
        throw RecorderError.outputFailed("Could not create audio file: \(error.localizedDescription)")
    }
}
```

#### パターン: SwiftUI header actions

**場所**: `meet-log/meet-log/Features/Library/LibraryView.swift`
**概要**: header は `Button + Label + systemImage` で主要 action を並べる。
**再利用方法**: Import action を `Label("Import Audio", systemImage: "square.and.arrow.down")` などで header に追加できる。

```swift
Button(action: viewModel.refresh) {
    Label("Refresh", systemImage: "arrow.clockwise")
}
.buttonStyle(.bordered)
```

### 2.3 類似実装の参考例

#### 参考: Library scan

**実装ファイル**: `meet-log/meet-log/Features/Library/RecordingLibraryStore.swift`
**類似点**: FileManager でファイル存在/ディレクトリ状態を確認し、失敗を typed error に変換する。
**参考になる点**: 外部ファイル URL に対しても存在確認、resourceValues による file size 取得、アクセス不可時の error 分類を同じ方針で実装できる。

#### 参考: Mixdown playback

**実装ファイル**: `meet-log/meet-log/Support/LibraryFileActions.swift`
**類似点**: ユーザーが選んだ音声 URL を AVFoundation API に渡す。
**参考になる点**: UI へ返す失敗文言は framework の生エラーではなく、短い説明に丸めている。

### 2.4 命名規則・コーディングスタイル

- **ファイル命名**: Swift は PascalCase (`LibraryViewModel.swift`, `RecordingLibraryItem.swift`)。
- **変数命名**: camelCase。
- **インデント**: 4 spaces。
- **UI**: SwiftUI `View` は小さな private subview に分割。Buttons は `Label` + SF Symbols を使用。
- **テスト**: Swift Testing の `@Test` と `#expect` を使用。`describe` 相当のネストはない。

---

## 3. 技術的制約・リスク

### 3.1 既存の制約

**型システム・リンター**:
- Swift Concurrency を使い、UI state は `@MainActor` view model で管理する。
- app target の domain structs は internal が基本。framework public API は `DualTrackRecorder` に限定されている。

**ビルド設定**:
- ビルドツール: Xcode project (`meet-log/meet-log.xcodeproj`)
- 対象環境: macOS native app
- テスト: `xcodebuild test -project meet-log/meet-log.xcodeproj -scheme meet-log`

### 3.2 互換性の問題

| ライブラリ | バージョン | リスク |
|-----------|----------|--------|
| AVFoundation | macOS SDK | `AVAudioFile` が拡張子だけでなく実データを見て失敗するため、unsupported と corrupted の分類は事前拡張子チェック + 読み込み失敗理由の組み合わせになる |
| SwiftUI fileImporter | macOS app target | security-scoped resource が必要になる sandbox 設定の場合がある。現状 entitlement ファイルは未確認 |
| UniformTypeIdentifiers | macOS SDK | mp3 / m4a / wav の UTType 指定を使う場合、fallback 拡張子チェックも持つと堅い |

### 3.3 パフォーマンスボトルネック

- ファイル全体を `Data` として読み込む実装は避ける。
- `AVAudioFile(forReading:)` と metadata extraction は async task 経由で行い、SwiftUI main thread を塞がない。

### 3.4 セキュリティ考慮点

- ユーザー選択ファイルは security-scoped access を開始/終了する可能性を考慮する。
- 選択された URL を後続パイプラインへ渡す場合、永続アクセスが必要なら bookmark data の検討が必要。ただし Issue #4 の完了条件では「投入できる」「後続パイプラインへ渡せる」までで、永続化は必須ではない。

---

## 4. 変更影響範囲

### 4.1 波及ファイル

**直接影響**（修正が必須）:
| ファイルパス | 理由 | 影響の種類 |
|-------------|------|-----------|
| `meet-log/meet-log/Features/AudioImport/AudioImportItem.swift` | import 結果のメタ情報モデル追加 | 追加 |
| `meet-log/meet-log/Features/AudioImport/AudioImportError.swift` | UI 説明可能な typed error 追加 | 追加 |
| `meet-log/meet-log/Features/AudioImport/AudioFileImporter.swift` | `AVAudioFile` 検証と metadata extraction | 追加 |
| `meet-log/meet-log/Features/AudioImport/AudioImportViewModel.swift` | fileImporter 結果を受ける UI 状態管理 | 追加 |
| `meet-log/meet-log/Features/Library/LibraryView.swift` | Import button と import 状態表示の導線 | 修正 |
| `meet-log/meet-logTests/AudioImportTests.swift` | importer / view model tests | 追加 |

**間接影響**（確認が必要）:
| ファイルパス | 理由 | 確認内容 |
|-------------|------|---------|
| `meet-log/meet-log/App/AppRootView.swift` | AudioImport を Library 内に収めるか destination 追加するか | UI 導線 |
| `meet-log/meet-log/App/meet_logApp.swift` | window size の影響 | Library header に収まるか |
| `meet-log/AppInfo.plist` | Speech usage key は既にある | import 単体で追加 permission が必要ないこと |
| `Task/31-apple-official-transcription-availability.md` | 後続 pipeline との境界 | #5 以降へ渡す型が過剰に閉じないこと |

### 4.2 テスト範囲

**既存テストファイル**:
| テストファイルパス | テスト対象 | 修正の必要性 |
|------------------|----------|------------|
| `meet-log/meet-logTests/RecordingLibraryTests.swift` | Library domain/view model | 低 |
| `meet-log/DualTrackRecorderTests/*` | recorder core | 低 |

**新規テストの必要性**:
- [x] ユニットテスト: extension/type validation, file size formatting, duration calculation with fake metadata reader
- [x] 統合テスト: temp file URL handling and importer error mapping where feasible
- [ ] E2Eテスト: file picker は手動確認で十分

### 4.3 破壊的変更の可能性

| API / 関数 | 変更内容 | 影響範囲 |
|-----------|---------|---------|
| なし | 既存 public API を変更せず、新規 app feature として追加可能 | 低 |

### 4.4 移行計画の必要性

- 段階的リリース: 不要。新規 import 導線として追加できる。
- ロールバック計画: Library の import button と `Features/AudioImport` 追加を戻せば既存録音機能への影響は限定的。

---

## 5. テストインフラストラクチャ

### 5.1 テスト環境

- **テストフレームワーク**: Swift Testing
- **テストランナーコマンド**: `xcodebuild test -project meet-log/meet-log.xcodeproj -scheme meet-log`
- **アサーションライブラリ**: `#expect`
- **モックライブラリ**: 外部 mock ライブラリなし。fake struct/class を手書き。

### 5.2 テストファイル構成

- **配置パターン**: target ごとに `meet-log/meet-logTests` と `meet-log/DualTrackRecorderTests`
- **命名規則**: `*Tests.swift`
- **テストヘルパー**: テストファイル内 private helper (`makeTemporaryDirectory`, fake provider)

### 5.3 既存テストパターン

| テストファイル | テスト対象 | パターン |
|-------------|----------|---------|
| `meet-log/meet-logTests/RecordingLibraryTests.swift` | Library item/store/view model | Unit + temp directory + fake provider |
| `meet-log/DualTrackRecorderTests/FakeRecorderHarness.swift` | recorder orchestration | fake dependencies |
| `meet-log/DualTrackRecorderTests/OutputDirectoryTests.swift` | file IO | temp directory |

### 5.4 カバレッジ・CI

- **カバレッジツール**: 未確認
- **CI テストジョブ**: 既存 spec `001-github-actions-ci-release` があるが、現在の探索範囲では workflow ファイル未確認

---

## 6. 追加調査が必要な項目

- [ ] アプリ sandbox / entitlement の有無。security-scoped resource が実行時に必要か確認する。
- [ ] `fileImporter` の allowed content types に `.mp3`, `.mpeg4Audio`, `.wav` を使える SDK バージョンか確認する。
- [ ] 後続 pipeline (#5 以降) が必要とする入力型が URL + metadata だけで足りるか、transcription job ID なども必要か確認する。

---

## 7. ユーザー判断が必要な論点

該当なし

---

## 8. 探索メトリクス（自己検証用）

| 指標 | 基準 | 実績 |
|------|------|------|
| Read したファイル数 | 10 以上 | 14 |
| Grep 検索キーワード数 | 5 以上 | 10 |
| コードスニペット数 | 5 以上 | 5 |
| 逆引き検索実施 | 必須 | 実施済み |

**探索キーワード一覧**: AVAudioFile, AVFoundation, RecorderError, RecordingResult, RecordingLibrary, fileImporter, NSOpenPanel, UTType, security, NSSpeechRecognitionUsageDescription
**Read したファイル一覧**:
- `README.md`
- `Task/implementation-plan.md`
- `Task/31-apple-official-transcription-availability.md`
- `meet-log/AppInfo.plist`
- `meet-log/meet-log.xcodeproj/project.pbxproj`
- `meet-log/meet-log/App/AppRootView.swift`
- `meet-log/meet-log/App/meet_logApp.swift`
- `meet-log/meet-log/Features/Library/LibraryView.swift`
- `meet-log/meet-log/Features/Library/LibraryViewModel.swift`
- `meet-log/meet-log/Features/Library/RecordingLibraryItem.swift`
- `meet-log/meet-log/Features/Library/RecordingLibraryStore.swift`
- `meet-log/meet-log/Support/LibraryFileActions.swift`
- `meet-log/DualTrackRecorder/Sources/FileIO/TrackFileWriter.swift`
- `meet-log/meet-logTests/RecordingLibraryTests.swift`
