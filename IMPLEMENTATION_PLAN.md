# ぬるぬるHill 完成実装計画

正式表示名は「ぬるぬるHill ～街中ダウンヒル～」、英語名は「NuruNuru Hill – Town Downhill」です。リポジトリ名、Rojo project名、`Workspace.NuruNuruRollMap` など内部識別子は互換性維持のため変更しません。

## 共通保護対象

- `MapBuilder.server.lua` の既存コース生成部分
- コース座標、Roadの位置・順序・寸法、現在のコース長
- `StartPad`、`CourseSpawn`、`GoalTrigger`
- Baseplate退避処理
- 基準commit以降の履歴と未追跡ZIP

各Phaseは「実装チェックポイント」として静的確認後に保存し、Studio合格後にrestore pointとして確定します。Studio未確認のcommit名にstable、complete、fixedを使いません。

## Phase A スタート待機

- 目的: 入力前の落下を防ぎ、W／↑またはmobile STARTで一度だけ開始する。
- 対象: `Config.lua`、Remote定義、新規Start Server Script、新規Gravity Slide Client Script。
- 実装: ServerがCharacterを待機状態に固定し、開始要求を検証して解除。Player属性へphaseとserver timeを保存。Clientは開始入力とmobile buttonを担当。
- 自動確認: Remote境界、再生成、多重開始、timeout、接続解放、構文、Rojo sourcemap。
- Studio確認: 入力前停止、開始入力、拘束解除、再respawn、mobile button。
- 完了条件: Gate 1の開始項目をMakoが確認。
- 戻し方: Phase Aチェックポイントの親commitへ戻す方法を人間と選択。resetは自動実行しない。

## Phase B 重力滑走と左右ライン取り

- 目的: 人工的な速度固定を停止し、重力を残したまま左右だけ操作する。
- 対象: `Config.lua`、Gravity Slide Client Script、必要最小限のHumanoid初期化。
- 実装: 既存Probe controllerをflag停止。Road Raycast、床法線、進行接線、VectorForceによる横操作・摩擦・低速時だけの補助・速度上限を一つのwriterで管理。開始時だけ小さなImpulseを許可。
- 自動確認: `AssemblyLinearVelocity` 常時代入なし、CFrame/Tween移動なし、Force writer重複なし、Character再生成、nil安全性。
- Studio確認: 坂加速、平地減速、上り失速、左右、停止しにくさ、接地、コース完走可能性。
- 完了条件: Gate 1合格。
- 失敗時: Configで新controllerを停止し、通常Humanoid値へ復元。旧Probeは削除せず停止状態を維持。

## Phase C 接地・ジャンプ・着地

- 依存: Gate 1合格。
- 目的: 少数の追加コブで空中遷移と得点根拠を成立させる。
- 対象: 新規Jump System、Config、少数の追加物生成Script。既存Roadは移動しない。
- 自動確認: 二重判定、air/ground state、同一jump加点防止。
- Studio確認: 飛距離、空中操作、着地継続、連続jump。
- 完了条件: Gate 2のjump項目。
- 戻し方: 追加物生成flagを停止し、Phase B状態へ戻す。

## Phase D 壁衝突・回転・復帰

- 依存: Phase C。
- 目的: 壁接触を停止ペナルティではなく回転演出にする。
- 対象: 新規Collision System、Config。既存壁の位置は維持し、表示のみ別工程で隠す。
- 自動確認: cooldown、永久拘束、最低速度補助、角速度上限。
- Studio確認: 回転、非停止、張り付き防止、短時間復帰。
- 完了条件: Gate 2合格。
- 戻し方: collision演出flag停止。

## Phase E タイマー・最小UI

- 依存: Gate 1。
- 目的: TIME / SCORE / COMBOの最小表示とrun lifecycleを作る。
- 対象: Server Run State、Remote、Client HUD、Config。
- 自動確認: Server time、respawn reset、Remote validation。
- Studio確認: 読みやすさ、mobile safe area、開始同期。
- 完了条件: timerと最小HUDがrun単位で正しい。
- 戻し方: UI flag停止。

## Phase F 仮NPC・コンボ・スコア

- 依存: Gate 1、最小UI。
- 目的: 少数NPCの接触、ragdoll、連鎖、Server scoreを成立させる。
- 対象: NPC Server System、pool、Score Service、Remote、Config。
- 自動確認: 二重加点、距離・頻度・状態検証、回収上限。
- Studio確認: 巻き込み、連鎖、滑走継続、性能。
- 完了条件: Gate 3のNPC・combo・score。
- 戻し方: NPC spawn flag停止、pool回収。

## Phase G 仮港・海・ゴール・リトライ

- 依存: timerとscore。
- 目的: 既存GoalTriggerを起点に最小の終端game loopを完成する。
- 対象: 新規Goal Presentation、Result、Retry、港・海の追加生成。GoalTriggerは変更しない。
- 自動確認: 二重goal、server authority、run cleanup。
- Studio確認: 海接触、timer停止、result、retry。
- 完了条件: Gate 3合格。
- 戻し方: 新演出とUIのflag停止。

## Phase H カメラ

- 依存: Gate 2の物理安定。
- 目的: 速度感と進路視認性を両立する近接追従／POV。
- 対象: `DownhillCamera.client.lua` または後継Client Script、Config。
- 自動確認: Character再生成、CameraType/FOV復元、connection解放。
- Studio確認: curve、jump、wall、海、PC/mobileの酔い。
- 完了条件: Gate 2 camera項目。
- 戻し方: camera flag停止でCustom cameraへ復元。

## Phase I 中世都市・分岐表現

- 依存: Gate 3。
- 目的: 既存Roadを動かさず、通りと二つの分岐・合流を視覚化する。
- 対象: 新規Town Decoration Server/Module、Config、Studio安全素材。
- 自動確認: Script混入、Part数、collision、Road clearance。
- Studio確認: 高速視界、街らしさ、見えない壁、分岐の読みやすさ。
- 完了条件: Gate 4の都市項目。
- 戻し方: decoration folder再生成flag停止。Courseには触れない。

## Phase J タンクローリー・ローション・演出

- 依存: 基本game loop。
- 目的: Start後方のtank lorry 2台と軽量な大量ローション表現。
- 対象: 新規Start Decoration、Particle/Beam/Sound、Config。
- 自動確認: effect上限、Scriptなし素材、Start clearance。
- Studio確認: 2台判別、大量放出、視界、frame rate。
- 完了条件: Gate 4のローション項目。
- 戻し方: effect qualityとsystem flag停止。

## Phase K mobile・最適化・公開前確認

- 依存: Gate 3。
- 目的: touch操作、低性能端末、総合回帰、公開準備。
- 対象: Input/HUD/Camera/Effect Config、必要なperformance修正。
- 自動確認: connection、Remote、sourcemap、diff、checklist。
- Studio確認: Device Emulator、Controller Emulator、Server & Clients、MicroProfiler、3～5分run。
- 完了条件: Gate 4と `docs/12_リリース前チェックリスト.md` 完了。
- 戻し方: 最後に合格したrestore pointへ戻す方法を人間と選択。

## Gate順序

1. Gate 1: Start、重力滑走、左右、坂・平地・上り、完走可能性。
2. Gate 2: Jump、air、landing、wall、camera。
3. Gate 3: NPC、combo、score、timer、goal、retry。
4. Gate 4: Town、lotion、mobile、performance、爽快感。
