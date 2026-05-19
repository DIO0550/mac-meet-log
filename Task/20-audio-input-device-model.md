# Task 20: Audio Input Device Model

## Goal

録音中にマイクを変更できるようにするため、利用可能な入力デバイスと選択中デバイスを core / UI で扱える値として定義する。

## Steps

- `DualTrackRecorder` に microphone input device を表す value type を追加する
- デバイス ID、表示名、既定デバイス判定を持たせる
- 現在の `RecordingSources` とは分けて、録音ソース on/off と入力デバイス選択を別概念にする
- fake / preview 用の固定デバイスを用意する

## Acceptance Criteria

- [ ] UI が入力デバイス一覧を型安全に表示できる
- [ ] 既定入力と明示選択された入力を区別できる
- [ ] source toggle の on/off と microphone device selection が混ざらない
- [ ] device ID は録音中の切り替え API に渡せる

## Tests

- [ ] value type の Equatable / Sendable 境界
- [ ] default device と explicit device の表示名生成
