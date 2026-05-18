# Task 17: Completion And Finder

## Goal

保存完了表示と「Finder で表示」を実装する。

## Steps

- `RecordingCompleteView` を追加する
- 録音時間を表示する
- `RecordingResult.displayFileName` を表示する
- Finder で mixdown file を reveal する処理を追加する
- dismiss と次回録音開始の挙動を実装する

## Acceptance Criteria

- [ ] stop 後に録音時間が表示される
- [ ] stop 後にファイル名が表示される
- [ ] 保存完了表示が自動で消えない
- [ ] Finder で表示が動作する
- [ ] 次の録音開始時に前回 completion が消える

## Manual Checks

- [ ] mixdown ファイルが Finder で選択される
- [ ] ファイルがない場合に保存先 folder を開く fallback がある
