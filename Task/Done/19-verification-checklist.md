# Task 19: Verification Checklist

## Goal

MVP の完了判定に必要な自動テストと実機確認をまとめて実施する。

## Commands

```sh
xcodebuild test -project meet-log/meet-log.xcodeproj -scheme meet-log -destination 'platform=macOS'
```

## Automated Checks

- [ ] app target build
- [ ] framework target build
- [ ] `DualTrackRecorderTests`
- [ ] app UI smoke test

## Manual Checks

- [ ] システム音声のみで録音できる
- [ ] マイクのみで録音できる
- [ ] 両系統で録音できる
- [ ] pause / resume 後の音声が再生できる
- [ ] mixdown が `~/Music/meet-log/` に保存される
- [ ] 素材 track が source に応じて保存される
- [ ] 保存完了表示が残る
- [ ] Finder で表示が動作する
- [ ] 権限拒否時にクラッシュしない

## Done Criteria

- [ ] 完了したタスクファイルを `Task/Done/` に移動している
- [ ] README または `meet-log-plan.md` に実装済み範囲を反映している
- [ ] 未解決の制約や既知の問題を記録している
