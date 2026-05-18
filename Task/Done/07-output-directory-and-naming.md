# Task 07: Output Directory And Naming

## Goal

保存先とファイル名ルールを core に閉じ込める。

## Steps

- `OutputDirectory` を追加する
- `~/Music/meet-log/` を解決する
- ディレクトリがなければ作成する
- ファイル名生成を実装する

## Acceptance Criteria

- [ ] 保存先が `~/Music/meet-log/` に固定されている
- [ ] 保存先がない場合に作成される
- [ ] mix / system / microphone のファイル名を生成できる
- [ ] ファイル名に date を含め、衝突しにくい

## Proposed Naming

- `yyyy-MM-dd_HH-mm-ss_mix.m4a`
- `yyyy-MM-dd_HH-mm-ss_system.m4a`
- `yyyy-MM-dd_HH-mm-ss_microphone.m4a`
