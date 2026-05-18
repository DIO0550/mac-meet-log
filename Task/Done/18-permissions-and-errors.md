# Task 18: Permissions And Errors

## Goal

権限、Info.plist、ユーザー向けエラー表示を整える。

## Steps

- `NSMicrophoneUsageDescription` を設定する
- Process Tap の entitlement / runtime 要件を確認する
- `RecorderError` を UI 表示文に変換する
- 権限拒否時の復旧導線を用意する

## Acceptance Criteria

- [ ] 初回マイク利用時の prompt 文が適切
- [ ] 権限拒否時にクラッシュしない
- [ ] Process Tap 作成失敗時に failed state になる
- [ ] output directory 作成失敗時に failed state になる
- [ ] UI に実装詳細すぎるエラー文が出ない

## Manual Checks

- [ ] マイク権限未許可
- [ ] マイク権限拒否
- [ ] 保存先作成失敗を再現できる範囲で確認
