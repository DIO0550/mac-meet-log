# Tasks: Audio Import

## Scope Guard

- このファイルは Issue #4 Audio Import の実装開始前計画である。
- チェックボックスは実装前のため、すべて未完了のままにする。
- 出力対象は app target の `Features/AudioImport` と Library 導線、`meet-logTests` の追加テストに限定する。
- `DualTrackRecorder` framework の public API は変更しない。
- 音声の文字起こし実行、Foundation Models 連携、import 履歴の永続化、bookmark data 永続化は Issue #4 の範囲外とする。

## Implementation Tasks

### 1. AudioImport domain 型を追加する

- [x] `meet-log/meet-log/Features/AudioImport/` ディレクトリを追加する。
- [x] `AudioImportItem.swift` を追加する。
- [x] `AudioImportItem` に `id`, `url`, `fileName`, `fileExtension`, `byteSize`, `duration`, `channelCount`, `sampleRate` を持たせる。
- [x] `AudioImportItem` を `Equatable`, `Sendable`, `Identifiable` に準拠させる。
- [x] `AudioImportError.swift` を追加する。
- [x] `AudioImportError` に `unsupportedFormat`, `fileNotFound`, `emptyFile`, `permissionDenied`, `unreadable`, `metadataUnavailable` を定義する。
- [x] `AudioImportError` を `Equatable`, `LocalizedError`, `Sendable` に準拠させる。
- [x] 各 error case が UI 表示可能な `errorDescription` を返すようにする。

Validation:

```sh
xcodebuild test -project meet-log/meet-log.xcodeproj -scheme meet-log
```

### 2. Audio importer protocol と AVFoundation 実装を追加する

- [x] `AudioFileImporter.swift` を追加する。
- [x] `AudioFileImporting` protocol に `func importAudio(from url: URL) async throws -> AudioImportItem` を定義する。
- [x] `AVAudioFileImporter` を追加する。
- [x] 対応拡張子を `mp3`, `m4a`, `wav` に限定する。
- [x] 拡張子判定は case-insensitive にする。
- [x] `startAccessingSecurityScopedResource()` と `stopAccessingSecurityScopedResource()` を対にして扱う。
- [x] `FileManager` または resource values で存在確認と byte size 取得を行う。
- [x] 0 byte file を `.emptyFile` に分類する。
- [x] `AVAudioFile(forReading:)` を主検証経路にする。
- [x] `AVAudioFile.length` と `fileFormat.sampleRate` から `Duration` を計算する。
- [x] sample rate、duration、length が不正な場合は `.metadataUnavailable` に分類する。
- [x] AVFoundation の throw は `.unreadable` に包む。
- [x] ファイル全体を `Data(contentsOf:)` で読み込まない。
- [x] import 処理を async 経路で実行し、UI main thread を塞がない。

Validation:

```sh
xcodebuild test -project meet-log/meet-log.xcodeproj -scheme meet-log
```

### 3. AudioImportViewModel を追加する

- [x] `AudioImportViewModel.swift` を追加する。
- [x] `@MainActor final class AudioImportViewModel: ObservableObject` として実装する。
- [x] `State` enum に `idle`, `importing`, `imported(AudioImportItem)`, `failed(AudioImportError)` を定義する。
- [x] `@Published private(set) var state` を追加する。
- [x] `@Published var isImporterPresented` を追加する。
- [x] initializer で `AudioFileImporting` を注入できるようにする。
- [x] `presentImporter()` を追加する。
- [x] `handleImporterResult(_:)` を追加し、file picker の success / cancel / failure を処理する。
- [x] 成功時は `idle -> importing -> imported` に遷移する。
- [x] typed error 時は `failed(AudioImportError)` に遷移する。
- [x] unknown error 時は `.unreadable` に丸める。
- [x] `clear()` で `idle` に戻せるようにする。

Validation:

```sh
xcodebuild test -project meet-log/meet-log.xcodeproj -scheme meet-log
```

### 4. LibraryView に import 導線を追加する

- [x] `LibraryView.swift` に `AudioImportViewModel` の `@StateObject` を追加する。
- [x] Library header に `Import Audio` button を追加する。
- [x] button には `Label` と SF Symbols を使う。
- [x] `fileImporter` を接続する。
- [x] allowed content types に mp3 / m4a / wav 相当を指定する。
- [x] 複数選択は無効にする。
- [x] `Result<[URL], Error>` から最初の URL を安全に取り出す。
- [x] 空選択または cancel は error として騒がず `idle` に戻す。
- [x] import 中は progress 表示を出す。
- [x] import 成功時は file name と ready 状態を表示する。
- [x] import 失敗時は typed error の説明を表示する。
- [x] 既存 Library refresh / list / detail の挙動を壊さない。

Validation:

```sh
xcodebuild test -project meet-log/meet-log.xcodeproj -scheme meet-log
```

Manual validation:

```text
1. app を起動する。
2. Library 画面で Import Audio を押す。
3. mp3 / m4a / wav ファイルを選択できることを確認する。
4. import 成功時に ready 表示が出ることを確認する。
5. 非対応拡張子または破損ファイルで説明可能な error 表示が出ることを確認する。
```

### 5. Data Transformation テストを追加する

- [x] `meet-log/meet-logTests/AudioImportTests.swift` を追加する。
- [x] `AudioImportError` の `errorDescription` が主要ケースで空にならないことを確認する。
- [x] `.mp3`, `.MP3`, `.m4a`, `.wav` が対応形式として扱われることを確認する。
- [x] `.aac`, `.txt`, 空拡張子が `.unsupportedFormat` になることを確認する。
- [x] 存在しない URL が `.fileNotFound` になることを確認する。
- [x] 0 byte file が `.emptyFile` になることを確認する。
- [x] 一時 wav fixture を生成できる場合、duration、sample rate、channel count、byte size が `AudioImportItem` に入ることを確認する。

Validation:

```sh
xcodebuild test -project meet-log/meet-log.xcodeproj -scheme meet-log
```

### 6. Async Operations テストを追加する

- [x] `FakeAudioFileImporter` を test file 内に追加する。
- [x] fake importer 成功時に `AudioImportViewModel` が `.imported` へ遷移することを確認する。
- [x] fake importer が `AudioImportError.unsupportedFormat` を throw した時に `.failed` へ遷移することを確認する。
- [x] fake importer が unknown error を throw した時に `.failed(.unreadable)` へ丸められることを確認する。
- [x] file picker cancel 相当の failure が import を開始しないことを確認する。
- [x] `presentImporter()` が `isImporterPresented` を `true` にすることを確認する。

Validation:

```sh
xcodebuild test -project meet-log/meet-log.xcodeproj -scheme meet-log
```

### 7. UI Component 確認を行う

- [ ] Library header の既存 Refresh button と Import Audio button が視覚的に破綻しないことを確認する。
- [ ] import 中の progress 表示が Library list / detail と重ならないことを確認する。
- [ ] 成功表示が長い file name でも崩れないことを確認する。
- [ ] error 表示が長い message でも崩れないことを確認する。
- [ ] `fileImporter` が mp3 / m4a / wav 選択に使えることを確認する。
- [ ] unsupported file の error 表示を手動で確認する。
- [ ] 破損ファイルの error 表示を手動で確認する。

Validation:

```text
Local macOS app で手動確認する。
```

### 8. Issue #4 完了確認

- [ ] 既存 mp3 ファイルを import できる。
- [ ] 既存 m4a ファイルを import できる。
- [ ] 既存 wav ファイルを import できる。
- [x] import 結果が `AudioImportItem` として app 内に保持される。
- [x] `AudioImportItem.url` を後続 Apple official API pipeline の入力として渡せる構造になっている。
- [x] typed import errors が UI に表示される。
- [x] import 処理がファイル全体をメモリに読み込まない。
- [x] import 処理が async で実行される。
- [x] `xcodebuild test -project meet-log/meet-log.xcodeproj -scheme meet-log` が成功する。
- [x] Issue #4 の範囲外である transcription 実行や import 履歴永続化を実装していない。

## Definition of Done Checklist

- [x] `Features/AudioImport/AudioImportItem.swift` が追加されている。
- [x] `Features/AudioImport/AudioImportError.swift` が追加されている。
- [x] `Features/AudioImport/AudioFileImporter.swift` が追加されている。
- [x] `Features/AudioImport/AudioImportViewModel.swift` が追加されている。
- [x] `LibraryView.swift` に Import Audio 導線が追加されている。
- [ ] mp3 / m4a / wav を選択できる。
- [x] `AVAudioFile(forReading:)` による読み込み検証が行われる。
- [x] 成功時に URL とメタ情報を持つ `AudioImportItem` が作成される。
- [x] 非対応拡張子、0 byte、存在しないファイル、アクセス不可、破損、metadata 不可が typed error になる。
- [x] UI が typed error を説明できる。
- [x] ファイル全体をメモリへ読み込んでいない。
- [x] import が UI main thread を長時間ブロックしない。
- [x] `meet-logTests/AudioImportTests.swift` が追加されている。
- [x] Data Transformation のテストが追加されている。
- [x] Async Operations のテストが追加されている。
- [ ] UI Component は view model テストと手動確認で検証されている。
- [x] `xcodebuild test -project meet-log/meet-log.xcodeproj -scheme meet-log` が成功する。
