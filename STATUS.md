# ぬるぬるHill 開発状況

最終更新: 2026-07-11

## 現在のPhase

Gate 1 Studio確認待ち: Phase A スタート待機 + Phase B 重力主体の最小滑走。

## 完了済み

- 既存コースのStartからGoalまでの接続状態を基準commitとして保存。
- Baseplate退避処理。
- Roblox Studio実践マニュアルとAI開発標準。
- Legacy Sled / Input / HUD / Round / Result / Goalのflag停止。
- 前進不能調査用Client/Server Probeの保存。

## 実装済み・Studio未確認

- Server authorityのスタート待機と一度だけの開始。
- W／↑とmobile START入力。
- Server timeによるrun開始属性。
- 重力を保持する横方向VectorForce制御。
- 平地減速、上り失速、低速時だけの補助、速度安全上限。
- Courseから3秒以上外れた場合のServer respawn。
- MapReady前に別位置へ出たCharacterを、CourseSpawn指定後に一度だけ再生成する初期化race対策。
- Character低摩擦物性と開始時だけの小さな下りImpulse。
- StartFlow 7段階ログ（入力検知、Remote発火、Server受信、検証通過、拘束解除、滑走遷移、初動）をStudio限定で追加。
- 開始拒否時のServer側理由ログ（`[StartServerReject]` / `[StartFlowFail]`）を追加。
- Waiting中のW/↑入力を`gameProcessedEvent`依存で取りこぼさないよう開始入力経路を補強。

## 未実装

- Jump / air / landing score。
- Wall回転演出と復帰。
- HUD、NPC、combo、score、result、retry。
- 港、海、中世都市、分岐、tank lorry、lotion演出。
- Camera採用、mobile左右UI、最適化、公開確認。

## 静的確認済み

- 基準開始時のlocal `main` と `origin/main` は一致。
- 未追跡ZIP以外はclean。
- `default.project.json` のRojo対象Service。
- 旧controllerが毎Heartbeatで速度を上書きする構造とProbe mode。
- `LotionSlideSystem` がHumanoidを通常値へ戻す競合候補。
- `DownhillCourse` のRoad cacheとraycast helper。
- `default.project.json` のJSON読込。
- Rojo sourcemap生成と一時rbxlx build。
- 新Server/Client Scriptがsourcemapへ含まれること。
- Markdown相対link、`git diff --check`。
- `MapBuilder.server.lua` と `default.project.json` が無変更であること。
- Active controllerに継続的CFrame/Tween/VehicleSeat/LinearVelocity/毎frame速度代入がないこと。
- `DownhillStartSystem` と `GravitySlideController` のStartFlowログ追加後もLuauエラーがないこと。
- `MapBuilder.server.lua` に今回の追加差分がないこと。

## Studio未確認

- 新Phase A/Bの全挙動。
- CharacterのNetworkOwner。
- input前の待機姿勢、開始解除、respawn。
- 坂加速、平地減速、上り失速、左右、接地、完走可能性。
- Rojo live sync後のScript AnalysisとOutput。

## 既知の不具合・リスク

- 旧 `DownhillController` は完成版ではなく、人工速度上書きとProbeを含む。
- Character Humanoidの標準接地制御が重力滑走を相殺する可能性がある。
- 現在のCourse/LotionはCustomPhysicalPropertiesがnilで、体感摩擦はStudio調整が必要。
- RojoとStudioは `127.0.0.1:34872` で接続確立。ただしPlay同期結果は未確認。
- 開始不能の再現経路はStudioで未確定。今回の修正は「Waiting中の入力取りこぼし」仮説に対する対策であり、Gate 1Aで実機ログ確認が必要。

## 最新復元ポイント

`920318463cc9863adaa7af543fff6afceabb6afd` — add Roblox Studio practical manual and AI development standard

## 次の工程

Gate 1A（開始）を先に実機確認し、StartFlowログの停止段を確定してからチェックポイントcommitを判断する。

## Mako確認項目

- 入力前に止まる。
- W／↑で一度だけ開始する。
- START buttonがtouch emulationで表示・動作する。
- 開始後に拘束が残らない。
- 坂で加速、平地で減速、上りで失速する。
- A/D／左右でlineを調整できる。
- respawn後に待機へ戻る。
- Outputに重大errorがない。

## Gate 1 Studio確認手順

1. StudioのPlayを停止した状態でRojoが `localhost:34872` へ接続中か確認する。
2. Script AnalysisとOutputを開き、Playを開始する。
3. Outputで `[DownhillStart] server start authority enabled` と `[GravitySlide] client controller enabled` を確認する。
4. Character出現後、`[DownhillStart] waiting` が出て、5秒待ってもStartPadから滑り落ちないことを確認する。
5. Characterが低い座り姿勢で、通常歩行とjumpができないことを確認する。
6. Wまたは↑を一度押す。`[DownhillStart] started` が一度だけ出て、Characterの拘束が解除されることを確認する。
7. ExplorerのPlayer属性で `DownhillPhase=Sliding`、`DownhillStartedAt` が0より大きいことを確認する。
8. Wを押し続けてもacceleratorにならず、A/Dまたは左右矢印でlineを調整できることを確認する。
9. `[GravitySlide]` logのroad、speed、forwardSpeed、slope、steerを見ながら、坂で加速、平地で緩やかに減速、上りで失速するか確認する。
10. 30～60秒滑走し、強制速度固定、空中浮遊、激しい回転、壁への永久拘束がないか確認する。
11. 意図的にCourse外へ落ち、約3秒後にrespawnして再びWaitingへ戻るか確認する。
12. Reset Characterを実行し、再度W／↑で開始できるか確認する。
13. Device Emulatorでtouch端末を選び、待機中だけSTART buttonが表示され、一度だけ開始できるか確認する。
14. Script AnalysisとServer/Client Outputに新規errorがないことを確認する。

異常がある場合は、発生した手順番号、Server/ClientどちらのOutputか、最初のerror全文、画面上の挙動、再現頻度を記録する。
