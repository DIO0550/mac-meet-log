# Task 05: Session Clock And Duration

## Goal

録音時間と pause / resume を扱う clock を core に実装する。

## Steps

- `RecordingClock` を追加する
- start time、paused duration、elapsed duration を計算する
- test 可能な clock dependency を導入する

## Acceptance Criteria

- [ ] recording 中の elapsed が進む
- [ ] paused 中は elapsed が進まない
- [ ] resume 後に pause 期間を除いた duration になる
- [ ] stop 時の `RecordingResult.duration` に利用できる

## Tests

- [ ] pause なしの duration
- [ ] pause 1 回の duration
- [ ] pause 複数回の duration
