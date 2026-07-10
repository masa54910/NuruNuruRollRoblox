# 10 ぬるぬるHill固有設計

## ゲームコンセプト

正式表示名は「ぬるぬるHill ～街中ダウンヒル～」、英語名は「NuruNuru Hill – Town Downhill」です。巨大な中世都市の下り坂を、乗り物ではなくRoblox Character自身で滑り続け、NPC巻き込み、jump、combo、港から海へのdiveを楽しむ物理アクションです。内部識別子は互換性のため現状維持します。

## 現在のPhase

基準commitは `920318463cc9863adaa7af543fff6afceabb6afd` です。コースとBaseplate退避を保護し、Gate 1のスタート待機と重力滑走を実装する段階です。前進不能の原因を調べるClient/Server Probeは保存されていますが、完成版controllerではありません。

## 確認済みのファイルと役割

| ファイル | コード上で確認した役割 |
| --- | --- |
| `Config.lua` | Project feature flags、Slide/Sled/Downhill/Course調整値 |
| `MapBuilder.server.lua` | Map生成、診断、HealthCheck、再試行、MapReady属性 |
| `DownhillCourse.lua` | `Road_####` と `FinishRamp` の並べ替え・cache・raycast補助 |
| `DownhillState.lua` | controllerとcamera間のlocal shared state、shake減衰 |
| `DownhillController.client.lua` | 入力、Road開始方向、速度Probe、minimal controller候補 |
| `DownhillPhysicsProbe.server.lua` | ServerでNetworkOwnerと速度保持を観測するProbe |
| `DownhillStartSystem.server.lua` | 待機拘束、開始要求検証、Server timer属性、落下復帰 |
| `GravitySlideController.client.lua` | 開始入力、mobile START、重力を残す横Forceと安全補助 |
| `DownhillCamera.client.lua` | Scriptable camera候補。現在flag停止 |
| `LotionSlideSystem.server.lua` | Humanoidを通常値へ戻すrestore-only処理 |
| Legacy各Script | Config flagがfalseなら早期return |

## Configフラグの現在値

| フラグ | 値 | 意味 |
| --- | --- | --- |
| `EnableStartRedBall` | false | Startの巨大赤markerを生成しない |
| `EnableDownhillController` | false | 旧Probe controller停止 |
| `EnableDownhillStartSystem` | true | Server start authority有効 |
| `EnableGravitySlideController` | true | Gate 1 controller有効 |
| `EnableDownhillCamera` | false | camera候補は停止 |
| `EnableDownhillJumpPhysics` | false | jump physicsは停止 |
| `EnableDownhillDebug` | true | debug出力有効 |
| `EnableDownhillMinimalMode` | true | minimal調査方針 |
| `EnableDownhillProbeLogs` | true | Probe log有効 |
| `EnableDownhillClientImpulseProbe` | false | Client一度押しProbe停止 |
| `EnableDownhillServerOwnershipProbe` | false | Server ownership Probe停止 |
| `EnableDownhillServerImpulseProbe` | false | Server一度押しは停止 |
| Legacy Sled/Input/HUD/Round/Result/Goal | false | 旧機能停止 |

## Map構造

`MapBuilder.server.lua` は `Workspace.NuruNuruRollMap` を生成し、少なくともCourse、Lotion、Start、Goalを診断対象とします。Roadは `Road_%04d`、末尾に `FinishRamp` があります。`Workspace.NuruNuruRollMapReady` は成功時trueになります。

### StartとGoal

- `StartPad`: `StartHeight + 6` を中心とするConcrete Part。code上のTransparencyは0.85。
- `CourseSpawn`: Start folder内の透明SpawnLocation。StartPad CFrameから `(0, 4, -8)` offset。
- Course開始位置: spawnから `(0, -6, -6)` offsetを基準に生成。
- `GoalTrigger`: Goal folder内。Finish方向の先へ生成され、CanTouch=true。

### Baseplate退避

Workspace直下で名前がBaseplateのBasePartを検出し、下面を `CourseSpawn.Y + 750` へ移動します。同時に `Anchored=true`、`CanCollide=false`、`CanTouch=false`、`CanQuery=false`、`Transparency=1` にします。この処理は保護対象です。

## HealthCheckと診断

Map root数、親、folder、Course/Lotion数、spawn/goal、BoundingBox、Start距離、先頭Partの高さ・透明度・size、flat/gap/uphill、最大隣接距離などを判定し、失敗時は再生成を試みます。Start赤markerはflag false時に削除されます。Mid/Goal markerの存在やStudio上の表示は、Play確認が必要です。

## Creator Store prefab

MapBuilderはStudio側の `ServerStorage.CreatorStorePrefabs` を任意入力として参照します。子があればcloneしてDecorationsへ配置し、なければ簡易Partへfallbackします。このfolderは現在のRojo `$path` 配下ではないため、導入時はStudio/place側資産として所在と安全確認結果を記録します。

## Downhill試作の現在状態

`DownhillCourse` はRoad名の数値順を進行順としてcacheします。旧 `DownhillController` とProbeはflag停止です。Gate 1では `DownhillStartSystem` が待機・開始・timer・復帰をServer管理し、`GravitySlideController` がW／↑／mobile STARTと左右入力を受け、単一VectorForceで横操作、転がり抵抗、非上り時の低速補助、速度超過制動を行います。重力と接触結果を残すため、滑走中にAssemblyLinearVelocity全体を毎frame固定しません。

## 確認済み事実と未確認事項

### コードで確認済み

- 上記Config flag値。
- Baseplate退避propertyと750 studs offset。
- Road cacheとraycast helperの存在。
- Client/Server Probeの存在と有効状態。
- Legacy scriptのflag guard。
- Camera codeは存在するがflag false。

### Studioで確認が必要

- 現在のPlayでコースが毎回一貫して接続されるか。
- Characterの実際のNetworkOwner。
- Client一度押し速度が直後、次frame、0.1秒、0.5秒で残るか。
- Road_0001→0002が視覚上の正しい下り方向か。
- 前方障害物、Humanoidの速度相殺、Rojo管理外Scriptの有無。
- Baseplateが実際に衝突不能で退避しているか。

## 絶対に壊さないもの

- 既存コース、座標、Road位置。
- `MapBuilder.server.lua`（原則変更禁止）。
- `StartPad`、`CourseSpawn`、`GoalTrigger`。
- Baseplate退避処理。
- Legacy停止flag。
- 基準復元ポイントと未追跡ZIP。

## Phase 2 実装順

1. 通常歩行と人工的な前進処理の停止。
2. 坂の重力による自然加速。
3. 平地での減速。
4. 上りでの失速。
5. 左右キーだけのライン取り。
6. ジャンプ。
7. POV camera。
8. カーブ追従。
9. 空中制御。
10. Ground Stick。
11. 壁衝突演出。
12. 着地演出。

一気に実装しません。各工程で一つの主制御、Studio Play、回帰確認、復元ポイントを必要とします。

## 候補設計と未決定事項

- 第一候補は重力と接触物性を基本とし、必要最小限の補助だけを加える方式。
- Impulseはjump・衝突・診断、VectorForceは限定的補助、LinearVelocityは自然物理との比較後に判断。
- ownershipをClient自動、Client明示、Serverのどれにするかは未決定。
- Humanoid Controlsの停止方法、平地最低速度、上り判定、Ground Stick強度も未決定。
- StreamingEnabled、mobile負荷、camera採用値は未確認。

未決定事項をConfig値が存在するだけで「採用済み」と扱いません。
