# Task 04: Recorder State Machine

## Goal

録音状態遷移を code 上で固定し、不正遷移を早めに検出できるようにする。

## Steps

- `idle`, `preparing`, `recording`, `paused`, `finalizing`, `complete`, `failed` を定義する
- `start`, `pause`, `resume`, `stop`, `dismiss` の遷移ルールを実装する
- state change を `RecorderEvent` として流せる形にする

## Acceptance Criteria

- [ ] `idle -> preparing -> recording` が表現できる
- [ ] `recording -> paused -> recording` が表現できる
- [ ] `recording/paused -> finalizing -> complete` が表現できる
- [ ] failed から dismiss で idle に戻せる
- [ ] 不正遷移は `RecorderError.invalidState` になる

## Tests

- [ ] 正常遷移
- [ ] pause / resume 遷移
- [ ] invalid transition
