# meet-log — 開発計画

> ステータス: MVP 実装統合済み / build 通過
> 最終更新: 2026-05-18

## 概要

macOS 上で会議の「システム音声 + マイク」を同時録音するネイティブアプリ。出力は音声ファイルのみ（動画なし）。ライブラリ/管理機能は持たず、録音そのものに集中する最小構成。段階的に拡張する。

## MVP スコープ

### 含む

- 単一コンパクトウィンドウ（≈ 420 × 580）
- 2系統ソース、各独立トグル: システム音声 / マイク
- レベル / 波形表示、大タイマー
- 状態遷移: `idle → recording →（pause / resume）→ stop → 保存完了 → idle`
- 保存完了表示: 録音時間 + ファイル名 + 「Finder で表示」。明示的に閉じる or 次の録音開始まで残す（自動で消さない。会議直後に離席して戻るケースを想定）
- ライト / ダークはシステム追従
- 保存先固定: `~/Music/meet-log/`

### 含まない（後フェーズ）

- ライブラリ / 拡張モード（980 × 640）
- Groups / Tags / Favorites / Recents
- auto-tag（録音内容の自動分類）
- Share
- メータースタイル切替（4種）
- 保存先の変更 UI
- 動画キャプチャ・画面範囲選択（Full / Window / Area）

## 実装状況（2026-05-18）

- `meet-log.xcodeproj` にアプリ本体 `meet-log` とコア framework `DualTrackRecorder` を構成済み。
- SwiftUI のコンパクト録音 UI、ソーストグル、レベル / 波形表示、タイマー、録音完了表示、Finder 表示導線を実装済み。
- `DualTrackRecorder` 側に状態管理、固定出力先 `~/Music/meet-log/`、トラックファイル書き込み、stop 時の mixdown、マイク取得、システム音声 tap、レベル / 波形イベントの土台を実装済み。
- Integration verification: `xcodebuild -project meet-log/meet-log.xcodeproj -scheme meet-log -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` は通過済み。

## 技術決定

| 項目 | 決定 | 補足 |
|---|---|---|
| 最小 macOS | 14.2+ | Core Audio Process Tap の要件 |
| システム音声取得 | Core Audio Process Tap（`CATapDescription` / `AudioHardwareCreateProcessTap`） | サードパーティのループバックドライバ（BlackHole 等）は不使用。画面録画権限も不要 |
| マイク取得 | AVAudioEngine | |
| ミックス戦略 | 2トラック並行保存 + stop 時に mixdown | 「自分の声が大きすぎ / 小さすぎ」のリカバリ余地を残す |
| 永続化 | なし | ライブラリ廃止により DB / メタデータ層は不要。ファイル管理は Finder 任せ |
| 出力先 | `~/Music/meet-log/`（固定） | 変更可能化は後フェーズ |
| UI フレームワーク | SwiftUI | |

供給網方針: サードパーティ / 野良ツール・ドライバを排除。Process Tap はこの方針と整合（ドライバ不要のため）。

## 構造（アーキテクチャ）

- リポジトリ: `meet-log`
- 単一 `.xcodeproj`（Workspace は使わない）
- ターゲット構成（すべて 1 プロジェクト内）:
  - **アプリ本体** `meet-log`（SwiftUI）→ コア framework を embed
  - **コア framework** `DualTrackRecorder`（SwiftUI 非依存。Foundation + CoreAudio + AVFoundation のみ）
  - （任意）`DualTrackRecorder` の unit test ターゲット
- 境界方針: core から UI を import 不能にする（コンパイラ強制の clean-arch 境界）。Process Tap + ミックスという最もコケやすい層を framework 側に隔離する。
- 命名方針: アプリ = 目的名（`meet-log`）、コア = メカニズム名（`DualTrackRecorder`）。レイヤごとに命名スコープを噛み合わせる。

## 既知の制限 / 次の確認

- この統合作業では unit test は実行していない。実行対象は build sanity のみ。
- 実機での長時間録音、マイク TCC、Process Tap の権限 / entitlement 挙動、生成ファイルの音質確認は未実施。
- 保存先は MVP 方針どおり固定で、保存先変更 UI は未実装。
- ライブラリ、タグ、共有、録音履歴などの管理機能は後フェーズ。

## 要確認

- pause / resume を MVP に含めるか。デザインには有り、状態遷移にも記載しているが、2トラック方式だとセグメント結合の実装コストが乗る。初版で外す選択肢も残す。
