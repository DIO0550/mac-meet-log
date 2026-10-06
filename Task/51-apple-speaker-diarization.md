# Apple公式APIによる自動話者分離の調査

- Issue: [#51](https://github.com/DIO0550/mac-meet-log/issues/51)
- 調査日: 2026-10-06
- 判断: 現行制約では自動話者分離の採用を保留し、[#50](https://github.com/DIO0550/mac-meet-log/issues/50) の手動割当を継続する。

## 調査対象と判断の範囲

対象は、一つのシステム音声トラックに混在する複数参加者へ、音声から話者IDと時間区間を自動付与する機能（speaker diarization）。マイク／システム音声の入力元判定、文字起こし、音声区間検出、実名の特定とは区別する。

Apple公式フレームワーク、オンデバイス処理、外部APIなし、追加モデル重みなしという条件を維持する。Appleが管理するSpeechの文字起こし用システムアセットは既存方針で許容されるが、アプリが話者分離モデルを別途入手・変換・同梱する方法は対象外。

公開Speech APIの結果に話者IDを確認できず、現行条件で採用できる話者分離の経路を確認できなかった。これはAppleの技術全体で話者分離が不可能という主張ではない。WWDC26のCore AI紹介には話者分離モデルの用途が登場するが、モデルを用意して実行する方式として説明されている。

## SDK確認

[Apple Speech SDK Audit](../.github/workflows/speech-sdk-audit.yml) が、利用可能なmacOS SDKから公開Speech symbol graphを抽出する。Xcode・SDK・ホストOS・アーキテクチャ、結果型と属性の公開宣言、話者関連の名前候補、CoreAIを含む関連frameworkの有無をログと実行サマリーに記録する。

SDK確認結果は実行後に追記する。ローカル作業環境はLinuxで、Xcode/macOS SDKや実音声による検証は行えない。名前候補が見つからないことだけを根拠にAPI不存在を断定せず、公開結果型と公式ドキュメントを照合する。CIで選択されたSDKと、最新公式資料のSDKは別々に記録する。

## 公式資料

- [SpeechTranscriber.Result](https://developer.apple.com/documentation/speech/speechtranscriber/result)
- [SpeechTranscriber.ResultAttributeOption](https://developer.apple.com/documentation/speech/speechtranscriber/resultattributeoption)
- [Speech updates](https://developer.apple.com/documentation/updates/speech)
- [Meet Core AI — WWDC26](https://developer.apple.com/videos/play/wwdc2026/324/)
