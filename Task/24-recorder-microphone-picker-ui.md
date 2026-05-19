# Task 24: Recorder Microphone Picker UI

## Goal

録音画面にマイク選択 UI を追加し、録音中でも入力デバイスを変更できるようにする。

## Steps

- `RecorderViewModel` に microphone devices / selected device / switching state を追加する
- 録音前は選択値を start 時の microphone capture に渡す
- 録音中は選択変更で `switchMicrophoneInput` を呼ぶ
- `RecorderControls` に microphone picker を追加する
- microphone source が off の場合は picker を disable する
- 切り替え中 / 失敗時の表示を追加する

## Acceptance Criteria

- [ ] 録音前にマイクを選択できる
- [ ] 録音中に picker からマイクを変更できる
- [ ] マイク off の場合は picker が操作不可になる
- [ ] 切り替え中の多重操作を防げる
- [ ] 切り替え失敗時に復旧可能なエラーが表示される

## Tests

- [ ] view model の selected device 更新
- [ ] recording 中の selection change が switch command を呼ぶ
- [ ] microphone off / finalizing 時の disabled state
