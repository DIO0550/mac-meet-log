# Task 15: Compact Recorder Layout

## Goal

MVP の 420 x 580 相当の単一ウィンドウ UI を作る。

## Steps

- `RecorderView` を追加する
- 大タイマー領域を作る
- level / waveform 領域を作る
- source toggle 領域を作る
- controls 領域を作る
- light / dark の system appearance に追従させる

## Acceptance Criteria

- [ ] 初期表示が録音アプリとして成立している
- [ ] ウィンドウがコンパクトサイズで破綻しない
- [ ] テキストや controls が重ならない
- [ ] ライブラリ UI や保存先変更 UI が入っていない

## Notes

- 既存 design HTML がある場合は見た目の参考にする
- 実 audio 未接続でも fake state で preview できるとよい
