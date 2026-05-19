# Task 25: Recording Library Domain

## Goal

保存済み録音をライブラリ画面で扱うため、録音ファイル群を 1 件の library item として読み取る domain model を追加する。

## Steps

- `RecordingLibraryItem` を追加する
- mixdown / system audio / microphone の URL、表示名、作成日時、duration を持たせる
- `~/Music/meet-log/` の既存ファイル命名規則から item を復元する
- 不完全なファイルセットの扱いを決める
- ライブラリ表示用の日付 / 長さ / source summary を生成する

## Acceptance Criteria

- [ ] 保存済み mixdown を library item として列挙できる
- [ ] 素材トラックがある場合は item に紐づく
- [ ] 素材トラックが欠けても mixdown があれば一覧表示できる
- [ ] 表示用 metadata が UI 非依存で生成できる

## Tests

- [ ] ファイル名から item を復元する unit test
- [ ] 欠損 track の扱い
- [ ] 作成日時順 sort
