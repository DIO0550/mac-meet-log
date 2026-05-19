# Task 22: Microphone Capture Selected Device

## Goal

`MicrophoneCapture` が既定入力だけでなく、選択されたマイクデバイスで録音を開始できるようにする。

## Steps

- `MicrophoneCapture` の初期化または start 引数で device ID を受け取る
- 選択デバイスに対応する input node / audio unit を設定する
- 選択デバイスが消えていた場合は typed error を返す
- capture 開始後の writer / processor との接続は既存のまま維持する

## Acceptance Criteria

- [ ] 明示選択したマイクから録音が開始できる
- [ ] 既定入力を選んだ場合は現行動作と同じになる
- [ ] 存在しない device ID では録音開始前に失敗する
- [ ] system audio only の録音には影響しない

## Tests

- [ ] selected device ID が capture factory へ渡る
- [ ] missing device の error mapping
- [ ] default device fallback の unit test
