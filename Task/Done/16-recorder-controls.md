# Task 16: Recorder Controls

## Goal

録音操作と source toggle を UI から実行できるようにする。

## Steps

- `RecorderControls` を追加する
- system audio toggle を追加する
- microphone toggle を追加する
- start / pause / resume / stop button を状態に応じて出し分ける
- 両 source off の start を UI で防ぐ

## Acceptance Criteria

- [ ] idle では start できる
- [ ] recording では pause / stop できる
- [ ] paused では resume / stop できる
- [ ] finalizing 中は操作を disable する
- [ ] 両 source off では start できない

## Tests

- [ ] view model command が正しく呼ばれる
- [ ] state 別 button availability
