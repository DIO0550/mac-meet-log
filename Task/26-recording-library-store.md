# Task 26: Recording Library Store

## Goal

ライブラリ画面が保存済み録音を読み込み、更新できる store / repository を実装する。

## Steps

- output directory を scan する library store を追加する
- 初回読み込み、手動 refresh、録音完了後 refresh を提供する
- ファイル削除や外部変更があっても安全に再読み込みする
- fake store を用意して UI と test で使えるようにする

## Acceptance Criteria

- [ ] 起動時に保存済み録音一覧を取得できる
- [ ] 録音完了後に新しい item が一覧へ出る
- [ ] Finder などでファイルが消えてもクラッシュしない
- [ ] loading / empty / failed state を表現できる

## Tests

- [ ] scan 結果の sort と filtering
- [ ] refresh 時の差分反映
- [ ] missing directory / unreadable file の error handling
