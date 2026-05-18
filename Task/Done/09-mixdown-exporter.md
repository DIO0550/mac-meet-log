# Task 09: Mixdown Exporter

## Goal

停止時に素材トラックから mixdown 音声を生成する。

## Steps

- `MixdownExporter` を追加する
- system / microphone の URL を入力にする
- 片系統のみの場合は mixdown として成立させる
- 完了後に mixdown URL を返す

## Acceptance Criteria

- [ ] 両系統の mixdown を生成できる
- [ ] system audio のみでも mixdown URL が返る
- [ ] microphone のみでも mixdown URL が返る
- [ ] mixdown failure が `RecorderError.mixdownFailed` になる

## Notes

- 音量調整 UI は MVP に含めない
- 音声フォーマット差分の扱いは exporter に閉じ込める
