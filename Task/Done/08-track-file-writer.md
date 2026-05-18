# Task 08: Track File Writer

## Goal

システム音声とマイクの素材トラックを個別に保存する writer を実装する。

## Steps

- `TrackFileWriter` を追加する
- input format を受け取り、`AVAudioFile` などで書き込む
- pause / resume を見越して segment を扱える API にする
- close 後に URL を返す

## Acceptance Criteria

- [ ] system audio track を書き込める
- [ ] microphone track を書き込める
- [ ] 片系統のみ有効でも動作する
- [ ] writer failure が `RecorderError.outputFailed` になる
- [ ] close 前後の不正操作を検出できる

## Tests

- [ ] fake buffer 書き込み
- [ ] close 後の result URL
- [ ] write failure
