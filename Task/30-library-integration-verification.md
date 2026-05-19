# Task 30: Library Integration Verification

## Goal

録音完了からライブラリ表示までの統合動作を確認し、design と既存 recorder 体験の両方を崩していないことを検証する。

## Steps

- 録音完了後に library store が更新されることを確認する
- recorder 画面から library 画面へ移動して新規録音を確認する
- library 画面から Finder 表示と再生を確認する
- `design/Recorder - Library.html` と主要な配置を照合する
- compact recorder の smoke test を再実施する

## Acceptance Criteria

- [ ] 新規録音がライブラリに表示される
- [ ] 既存録音もライブラリに表示される
- [ ] ライブラリから録音画面へ戻って再録音できる
- [ ] ライブラリ実装後も録音開始 / 停止 / 保存完了表示が動作する
- [ ] design の主要要素と画面構造が一致している

## Tests

- [ ] unit test
- [ ] UI smoke test
- [ ] 実機録音での manual verification
