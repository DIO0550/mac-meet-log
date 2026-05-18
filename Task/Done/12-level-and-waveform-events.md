# Task 12: Level And Waveform Events

## Goal

UI に表示する level / waveform を core から軽量な値として流す。

## Steps

- `AudioLevelMeter` を追加する
- buffer から peak / rms を計算する
- waveform 表示用の downsampled samples を生成する
- `RecorderEvent` に level / waveform event を追加する

## Acceptance Criteria

- [ ] system audio と microphone の level を区別できる
- [ ] waveform samples が UI 非依存の値で表現される
- [ ] イベント頻度が UI 更新に過剰すぎない
- [ ] silent input でも安定して 0 付近の値になる

## Tests

- [ ] silent buffer
- [ ] peak buffer
- [ ] stereo / mono 差分
