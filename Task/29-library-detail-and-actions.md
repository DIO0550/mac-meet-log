# Task 29: Library Detail And Actions

## Goal

ライブラリで選択した録音の詳細と、再生・Finder 表示・ファイル操作の基本アクションを提供する。

## Steps

- 選択 item の detail pane を追加する
- mixdown の再生 / 停止を実装する
- Finder で表示を実装する
- mixdown / system / microphone のファイル存在状態を表示する
- 削除は確認 dialog 付きで実装するか、後続タスクとして明示的に未実装にする

## Acceptance Criteria

- [ ] 選択した録音の詳細が表示される
- [ ] mixdown をアプリ内で再生できる
- [ ] Finder で mixdown または保存先を開ける
- [ ] 素材トラックの有無が確認できる
- [ ] ファイルが消えている場合は復旧可能な表示になる

## Tests

- [ ] selected item detail の表示 state
- [ ] playback command の start / stop
- [ ] missing file の error handling
