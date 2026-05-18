# Task 13: Recorder Orchestration

## Goal

`DualTrackRecorder` actor が capture、writer、mixdown、state event を統合する。

## Steps

- `DualTrackRecorder.start(sources:)` で session を作る
- source に応じて capture component を起動する
- writer と meter を接続する
- `stop()` で capture 停止、writer close、mixdown を順に行う
- 完了時に `RecordingResult` を返す

## Acceptance Criteria

- [ ] `start -> stop` で complete event と result が返る
- [ ] `pause -> resume` が clock と writer に反映される
- [ ] capture failure で failed event が流れる
- [ ] stop 中は `finalizing` state になる
- [ ] partial failure が complete として扱われない

## Tests

- [ ] fake component による orchestration test
- [ ] failure propagation test
