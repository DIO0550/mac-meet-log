# Apple公式APIによる自動話者分離の調査

- Issue: [#51](https://github.com/DIO0550/mac-meet-log/issues/51)
- 調査日: 2026-10-06
- 状態: 調査完了。公開資料と利用可能なSDKを確認し、現行制約での非採用理由を記録。
- 判断: 現行制約では自動話者分離の採用を保留し、[#50](https://github.com/DIO0550/mac-meet-log/issues/50) の手動割当を継続する。

## 調査対象と判断の範囲

対象は、一つのシステム音声トラックに混在する複数参加者へ、音声から話者IDと時間区間を自動付与する機能（speaker diarization）。マイク／システム音声の入力元判定、文字起こし、音声区間検出、実名の特定とは区別する。

Apple公式フレームワーク、オンデバイス処理、外部APIなし、追加モデル重みなしという条件を維持する。Appleが管理するSpeechの文字起こし用システムアセットは既存方針で許容されるが、アプリが話者分離モデルを別途入手・変換・同梱する方法は対象外。

公開Speech APIの結果に話者IDを確認できず、現行条件で採用できる話者分離の経路を確認できなかった。これはAppleの技術全体で話者分離が不可能という主張ではない。WWDC26のCore AI紹介には話者分離モデルの用途が登場するが、モデルを用意して実行する方式として説明されている。

## 公開API・対応OS

| API | macOS導入版 | 公開機能・結果 | 話者分離としての判断 |
|---|---|---|---|
| `SpeechAnalyzer` / `SpeechTranscriber` | 26.0 | 音声処理と文字起こし。`Result` は `text`、`alternatives`、`range`、`isFinal`、`resultsFinalizationTime`。属性は `audioTimeRange` / `transcriptionConfidence`。[S1][S2] | 話者ID・話者交代・声紋の出力を確認できない。認識区間や文字認識の信頼度は話者情報ではない。 |
| `DictationTranscriber` | 26.0 | 旧機種にも対応する文字起こし用module。結果は本文・代替候補・時間・確定状態。[S3] | 公開結果に話者IDを確認できない。現アプリのfallbackはこのmoduleではなくlegacy Speech。 |
| legacy Speech / `SFTranscriptionSegment` | 10.15 | 本文、代替候補、認識信頼度、`timestamp` / `duration`。`voiceAnalytics` はpitch / jitter / shimmer / voicing。[S4] | 安定した話者ID・話者埋め込みを返すAPIではない。声の特徴を取得できることだけでは会議の話者分離を満たさない。 |
| `SpeechDetector` | 26.0 | Voice Activity Detection（VAD、発話の有無の検出）。SDKの結果は `speechDetected`、時間範囲、確定状態。[S5] | 音声の存在と人物の区別は別。無音区間を話者変更とみなさない。 |
| Sound Analysis / `SNClassifySoundRequest` | 10.15 | 音カテゴリの分類。`SNClassificationResult` は時間範囲と分類候補。独自Core MLモデルを渡す方法もある。[S6] | 音カテゴリのidentifierは会議内の話者IDではない。独自モデルの用意は現行制約外。 |
| Core AI | 27.0 | オンデバイスのモデル実行。公式講演には話者分離モデルの用途があるが、`.aimodel` ファイルの用意・組み込み／ダウンロードが必要。[S7] | Apple管理の組み込み話者分離モデルを確認できない。追加モデルを使う方式は現行制約外。 |
| Foundation Models / `LanguageModelSession` | 26.0（27世代で拡張） | Appleモデルやmodel providerによる生成。最新資料では画像入力やproviderの拡張も扱う。[S8] | Appleのオンデバイスモデルで音声の話者ID・時間区間を返す公開機能を確認できない。本文から担当者を推測する処理は音声による話者分離とは別。 |

OS導入版は公式DocC JSONの `metadata.platforms` のmacOS項目で確認した。Core AIはframework本体のmetadataを根拠にする。`AIModel` 個別metadataにはmacOS項目が省略されている。アプリのdeployment targetは現在macOS 15.0であり、SpeechAnalyzer経路はmacOS 26.0とcompiler 6.2以降の条件で選択する。[S9]

## 日本語・機種・オンデバイスの条件

- 文字起こしの日本語対応と、話者分離の日本語対応を分けて扱う。後者の組み込みAPIを確認できないため、話者分離の日本語対応OS／機種を提示することはできない。
- `SpeechTranscriber.isAvailable` と `supportedLocale(equivalentTo: Locale(identifier: "ja-JP"))` を各環境で確認する。APIのOS導入版やApple Siliconという情報だけで、そのMacで認識が使えるとは保証しない。[S1]
- CIのlocale照会では `ja_JP` が返ったが、`isAvailable` はfalseだった。日本語localeが候補として存在するという結果であり、CIで日本語音声の認識に成功したという結果ではない。
- 公式ドキュメントJSONの `availableLanguages` は文書の翻訳言語であり、音声認識の対応localeの根拠にしない。
- SpeechTranscriberはApple管理の言語アセットを使う。初回のアセット取得に通信が必要な場合があり、オンデバイス処理は「初回ダウンロードも不要」を意味しない。現アプリは `AssetInventory` で準備する。[S10]
- legacy経路は `supportsOnDeviceRecognition` を確認して `requiresOnDeviceRecognition = true` を設定する。利用できないときにネットワーク認識へ切り替えない。[S4]

## 利用可能なSDKによる確認結果

[Apple Speech SDK Audit](../.github/workflows/speech-sdk-audit.yml) は、公開Speech symbol graphと関連frameworkの有無を調べ、音声認識・モデル取得を行わずにlocaleと実行可否を照会する。宣言一覧を実行ログとサマリーに残す。調査資料／workflowを変更したPR、または手動実行で再確認できる。外部Actionsは使わず、権限は `permissions: {}`。

確認した実行: [SDK Audit run 37438083492](https://github.com/DIO0550/mac-meet-log/actions/runs/37438083492)、2026-10-06、commit `167da4825be5f6b303b2f47713668223ffe3ec06`。

| 確認項目 | 実測結果 |
|---|---|
| Xcode | 26.6、build 17F113 |
| 利用可能なmacOS SDK | 26.5 |
| ホストOS / CPU | macOS 26.6.2、build 25G83 / arm64 |
| 関連framework | Speech・SoundAnalysis・CoreML・FoundationModelsあり。CoreAIなし。 |
| locale照会 | `ja-JP` に対して `ja_JP` を返した。 |
| 実行可否 | `SpeechTranscriber.isAvailable == false`。原因はこの照会だけでは特定しない。 |
| 公開結果型 | 上表のSpeech各結果型と属性を抽出。話者IDに相当する公開フィールドを確認できない。 |
| 名前候補の確認 | 公開Speech symbol名に `speaker` / `diari` を含むものなし。これは補助確認であり、単独の不存在証明には使わない。 |

確認した最新の公式資料にはSpeechのJune 2026更新、Core AI、Foundation Modelsの27世代の拡張、Xcode 27.2 betaのリリースノートを含む。Speech更新は入力sequence providerや音声変換の補助で、話者分離の追加は記載されていない。[S7][S8][S11]

**SDKで直接確認したのは26.5であり、27.x SDKを実行検査したとは扱わない。** Core AIのモデル要件は27世代の公式資料に基づく。SDKのframeworkの有無と、組み込み話者分離モデルの有無も区別する。ローカルはLinuxなので、Macでの確認は上記CIによる。

## 音声による精度・処理時間の評価

| 評価対象 | 結果・実施しない理由 |
|---|---|
| 同一トラックの複数話者 | 話者分離精度は未測定。制約を満たす話者ID出力の検証経路を確認できない。 |
| 重なり発話 | 話者別の重複時間区間の精度は未測定。2入力トラックの時刻順マージとは別の課題。 |
| 短い「はい」「うん」 | 話者割当精度は未測定。認識できた単語やVAD結果を人物IDとして使えない。 |
| 処理時間 | 話者分離の測定対象なし。SDK抽出時間・文字起こし時間を話者分離時間として報告しない。 |

Macで公開APIを利用できる条件の照会は実施したが、認識実行は不可の結果であり、評価音声を使う話者分離PoCは実施していない。公開資料と結果型の確認による実装可否判断と、実音声での性能検証を分けて記録する。

将来、制約を満たすAPIが公開された場合は、日本語の2人／3人会議、同時発話、短い相づちを含む同意済み音声に正解の話者・時間区間を付け、話者割当の誤り、重なり区間、短い発話の欠落、音声長に対する処理時間、OS／SDK／Mac機種／locale／アセット状態を記録して採用判断をやり直す。

## 現行実装と後続Issue

`TranscriptSpeaker.me / other` は入力元、`TranscriptSegment.participantID` と `MeetingParticipant` は人が指定した参加者を表す。匿名の話者A／Bを自動生成できても、Aを実名へ対応させるには別の確認が必要であり、基本は手動の名付けとする。

現行の `SpeechAnalyzerTranscriptionService.collectResults` は確定本文だけを結合し、`Result.range` を `TranscriptResult.segments` に保存していない。`TrackAwareTranscriptionService` はセグメントが空ならトラック全体を時刻0・継続時間0の1区間としてラベル付けする。この経路では複数発言の手動割当や時刻の利用が制限される。調査中に確認したこの問題は [#71](https://github.com/DIO0550/mac-meet-log/issues/71) に登録した。[S9]

| 判断・後続 | 対応 |
|---|---|
| 自動話者分離 | 現行制約での採用は保留。今回の調査は完了。 |
| 手動話者割当 | #50を継続し、SpeechAnalyzerの時間区間保持は#71で修正する。時刻を保持しても話者IDを自動生成する機能にはならない。 |
| 公開APIの再調査 | Apple管理の話者分離APIが公開され、OS・日本語・話者IDと時間区間・モデル管理条件が確認できた時点で新しい調査Issueを作る。定期監視は追加しない。 |
| 追加モデルを使う方式 | Core AI / Core ML経路を検討する場合は、追加モデル重みの許可、入手元・ライセンス・配布・更新・機種対応・評価費用を別Issueで判断してから着手する。今回はモデルを導入しない。 |

## 公式資料

- S1: [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)、[Result](https://developer.apple.com/documentation/speech/speechtranscriber/result)、[supportedLocale](https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocale(equivalentto:))
- S2: [ResultAttributeOption](https://developer.apple.com/documentation/speech/speechtranscriber/resultattributeoption)
- S3: [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber)、[Result](https://developer.apple.com/documentation/speech/dictationtranscriber/result)
- S4: [SFTranscriptionSegment](https://developer.apple.com/documentation/speech/sftranscriptionsegment)、[SFVoiceAnalytics](https://developer.apple.com/documentation/speech/sfvoiceanalytics)、[requiresOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)
- S5: [SpeechDetector](https://developer.apple.com/documentation/speech/speechdetector)
- S6: [Sound Analysis](https://developer.apple.com/documentation/soundanalysis)、[SNClassifySoundRequest](https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest)、[SNClassificationResult](https://developer.apple.com/documentation/soundanalysis/snclassificationresult)
- S7: [Core AI](https://developer.apple.com/documentation/coreai)、[Meet Core AI — WWDC26](https://developer.apple.com/videos/play/wwdc2026/324/)（話者分離の用途、モデルの変換・組み込み、`.aimodel` からの読み込み）、[Integrating on-device AI models](https://developer.apple.com/documentation/coreai/integrating-on-device-ai-models-in-your-app-with-core-ai)
- S8: [Foundation Models updates](https://developer.apple.com/documentation/updates/foundationmodels)、[What's new in Foundation Models — WWDC26](https://developer.apple.com/videos/play/wwdc2026/241/)、[Running a Core AI model in a Foundation Models session](https://developer.apple.com/documentation/foundationmodels/running-a-core-ai-model-in-a-foundation-models-session)
- S9（実装根拠）: [SpeechAnalyzerTranscriptionService](../meet-log/meet-log/Features/Transcription/SpeechAnalyzerTranscriptionService.swift)、[TrackAwareTranscriptionService](../meet-log/meet-log/Features/Transcription/TrackAwareTranscriptionService.swift)、[TranscriptResult](../meet-log/meet-log/Features/Transcription/TranscriptResult.swift)、[TranscriptionServiceFactory](../meet-log/meet-log/Features/Transcription/TranscriptionServiceFactory.swift)、[Xcode project](../meet-log/meet-log.xcodeproj/project.pbxproj)。確認したmainは `2152de2`。
- S10: [Bring advanced speech-to-text to your app with SpeechAnalyzer — WWDC25](https://developer.apple.com/videos/play/wwdc2025/277/)
- S11: [Speech updates](https://developer.apple.com/documentation/updates/speech)、[Xcode 27.2 beta release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes)

OS導入版の一次データ: [SpeechAnalyzer JSON](https://developer.apple.com/tutorials/data/documentation/speech/speechanalyzer.json)、[SpeechTranscriber JSON](https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber.json)、[DictationTranscriber JSON](https://developer.apple.com/tutorials/data/documentation/speech/dictationtranscriber.json)、[SpeechDetector JSON](https://developer.apple.com/tutorials/data/documentation/speech/speechdetector.json)、[SFTranscriptionSegment JSON](https://developer.apple.com/tutorials/data/documentation/speech/sftranscriptionsegment.json)、[SNClassifySoundRequest JSON](https://developer.apple.com/tutorials/data/documentation/soundanalysis/snclassifysoundrequest.json)、[Core AI JSON](https://developer.apple.com/tutorials/data/documentation/coreai.json)、[LanguageModelSession JSON](https://developer.apple.com/tutorials/data/documentation/foundationmodels/languagemodelsession.json)。
