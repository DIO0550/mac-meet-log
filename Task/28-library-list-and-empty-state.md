# Task 28: Library List And Empty State

## Goal

保存済み録音の一覧、検索または絞り込み、空状態をライブラリ画面に表示する。

## Steps

- `LibraryView` に recording item list を追加する
- 各 item にタイトル、作成日時、duration、source summary を表示する
- 空状態を design に合わせて表示する
- 一覧の選択状態を view model に保持する
- refresh action を追加する

## Acceptance Criteria

- [ ] 保存済み録音が新しい順で表示される
- [ ] item を選択できる
- [ ] 録音が 0 件の場合に空状態が表示される
- [ ] refresh で最新の output directory 状態が反映される
- [ ] 長いファイル名でも layout が崩れない

## Tests

- [ ] empty / loading / loaded の view model state
- [ ] item selection
- [ ] sort order
