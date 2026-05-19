# Task 21: Microphone Device Discovery

## Goal

macOS の現在利用可能なマイク入力デバイスを列挙し、UI へ表示できるようにする。

## Steps

- AVFoundation または CoreAudio で audio input device を列挙する
- 既定入力デバイスを取得する
- デバイス追加 / 削除 / 既定入力変更を検知する
- `RecorderClient` 経由で view model から取得できる API を用意する
- 権限未許可時でも可能な範囲で一覧表示または復旧導線を返す

## Acceptance Criteria

- [ ] 起動時にマイク一覧が取得できる
- [ ] 既定入力デバイスが UI で識別できる
- [ ] USB / Bluetooth マイクの接続変更が一覧へ反映される
- [ ] 権限拒否時にクラッシュせずエラー表示へ変換できる

## Tests

- [ ] fake device provider による一覧取得テスト
- [ ] device change event の view model 反映テスト
- [ ] 権限拒否時の error mapping テスト
