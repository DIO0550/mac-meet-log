# Hearing Notes: Audio Import

## 目的

GitHub Issue #4 に基づき、既存の mp3 / m4a / wav 音声ファイルをアプリに投入し、Apple 公式 API による後続処理へ渡せる入力として扱えるようにする。

## スコープ

- **種別**: 新規機能
- **影響範囲**: 既存アプリへの入力導線追加 + 新規ドメイン/サービス追加
- **優先度**: 高

## 技術的詳細

- **技術スタック**: Swift / SwiftUI / AVFoundation
- **フレームワーク**: macOS ネイティブアプリ、`DualTrackRecorder` framework、SwiftUI app target
- **依存関係**: `AVAudioFile` を読み込み検証の主経路にする。将来の Speech / Foundation Models パイプラインへ渡せる URL とメタ情報を返す。
- **データ構造**: 音声ファイル URL、ファイル名、長さ、形式、サイズ、読み込み可否、typed import error を表す値型を追加する想定。

## 品質要件

- **エッジケース**: 非対応拡張子、AVFoundation で開けないファイル、破損ファイル、権限/セキュリティスコープ由来のアクセス不可、長さを取得できないファイル、0 byte ファイル。
- **エラーハンドリング**: 形式、権限、破損/読み込み不可が UI で説明できる粒度の typed error を返す。
- **テスト要件**: ファイルメタ情報抽出とエラー分類はユニットテストを追加する。実ファイル/AVFoundation 依存部分は小さなアダプタに閉じ込め、テスト可能な境界を設ける。
- **パフォーマンス**: インポート時にファイル全体をメモリへ読み込まない。メタ情報取得と検証は UI をブロックしない async 経路にする。

## 追加コンテキスト

- 関連 Issue: https://github.com/DIO0550/mac-meet-log/issues/4
- Parent: #2
- `Task/31-apple-official-transcription-availability.md` では、#4 は `AVAudioFile` で音声ファイルを検証し typed import errors を返す後続 Issue と位置づけられている。
- 対象形式は mp3 / m4a / wav を優先し、`AVFoundation` で読み込める形式は将来的に拡張可能にする。

## 探索後ユーザー判断

該当なし
