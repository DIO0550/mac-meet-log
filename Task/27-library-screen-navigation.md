# Task 27: Library Screen Navigation

## Goal

`design/Recorder - Library.html` にあるライブラリ画面をアプリ内で開けるようにし、録音画面との行き来を実装する。

## Steps

- `Features/Library/` フォルダを追加する
- `LibraryViewModel` と `LibraryView` の最小構成を追加する
- app root で recorder / library を切り替える navigation を追加する
- design の expanded library 画面に合わせた window size / layout 方針を設定する
- recorder 画面へ戻る導線を追加する

## Acceptance Criteria

- [ ] アプリからライブラリ画面を開ける
- [ ] ライブラリ画面から録音画面へ戻れる
- [ ] 既存の compact recorder layout が壊れない
- [ ] window size が library view に必要な最小サイズを満たす

## Tests

- [ ] navigation state の unit test
- [ ] recorder / library 切り替えの UI smoke test
