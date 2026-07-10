# ぬるぬるRoll（NuruNuruRoll）

巨大な下り坂コースを、プレイヤー自身の物理挙動で高速滑走するRobloxゲームです。現在はコース生成を保護したまま、Phase 2の重力滑走を一工程ずつ検証する準備段階です。

## 現在の状態

- 基準復元ポイント: `3c2521bf2dc77ad3357abfa4e9b6116d6f53f1bc`
- 既存コースは `StartPad` から `GoalTrigger` まで生成される構成
- Baseplateは `CourseSpawn` より750 studs上へ退避し、衝突・接触・Queryを無効化
- Legacy Sled / Input / HUD / Round / Result / GoalはConfigフラグで停止
- Downhill Controllerは前進不能の原因調査用Probeモード
- Downhill CameraとJump Physicsは停止
- Phase 2のゲームコードは未完成。Studioでの採用判断も未完了

「コードに存在する」と「Studioで動作確認済み」は別です。現在の確定事項は[ぬるぬるRoll固有設計](docs/10_ぬるぬるRoll固有設計.md)を参照してください。

## 技術構成

- Roblox Studio / Luau
- Rojo 7.x（既定ポート `34872`）
- VS Code / Git / GitHub
- Server: `src/ServerScriptService`
- Shared: `src/ReplicatedStorage`
- Client: `src/StarterPlayer`

## 開発開始時に読む順番

1. [`AGENTS.md`](AGENTS.md)
2. このREADME
3. [`docs/10_ぬるぬるRoll固有設計.md`](docs/10_ぬるぬるRoll固有設計.md)
4. 作業内容に対応する章
5. [`docs/09_AI実装ワークフロー.md`](docs/09_AI実装ワークフロー.md)

## フォルダ構成

```text
NuruNuruRollRoblox/
├─ AGENTS.md
├─ README.md
├─ default.project.json
├─ .github/copilot-instructions.md
├─ docs/
└─ src/
   ├─ ReplicatedStorage/Shared
   ├─ ServerScriptService/Server
   └─ StarterPlayer/StarterPlayerScripts/Client
```

## Rojo起動と接続確認

プロジェクトルートで実行します。

```powershell
rojo serve default.project.json
```

StudioのRojoプラグインから `localhost:34872` へ接続し、`ReplicatedStorage`、`ServerScriptService`、`StarterPlayer` が `default.project.json` どおりに同期されることを確認します。Studioだけの変更はRojoの同期で上書きされ得るため、ソース管理対象はローカルファイルを正とします。詳細は[StudioとRojo運用](docs/01_StudioとRojo運用.md)を参照してください。

## 基本テスト

1. `git status --short` と差分を確認
2. `rojo sourcemap default.project.json -o sourcemap.json`
3. StudioでRojo接続を確認
4. Script Analysisに新規エラーがないことを確認
5. PlayでServer / Client Outputを確認
6. Network関連はServer & Clientsでも確認
7. 人間が操作感・見た目・コース接続を確認

## Git運用

一工程ごとに、対象ファイルだけをステージします。Studio確認前の作業保存と、確認後の復元ポイントを区別してください。`reset`、`clean`、force pushは通常使用しません。競合時はpullやmergeを自動実行せず停止します。詳細は[Gitと復元ポイント運用](docs/08_Gitと復元ポイント運用.md)を参照してください。

## Creator Store素材

街や装飾のprefabを将来使用する場合は、Studio側の `ServerStorage/CreatorStorePrefabs` に安全確認済みmodelを配置します。`MapBuilder.server.lua` はこのfolderに内容があればcloneし、空または存在しない場合は簡易Partへfallbackします。Free ModelはScript、Remote、外部require、課金処理を確認してから導入し、Rojo管理外のStudio資産であることを記録してください。

## マニュアル

- [全体設計](docs/00_全体設計.md)
- [StudioとRojo運用](docs/01_StudioとRojo運用.md)
- [Luauコーディング標準](docs/02_Luauコーディング標準.md)
- [クライアントサーバー設計](docs/03_クライアントサーバー設計.md)
- [キャラクター物理と滑走](docs/04_キャラクター物理と滑走.md)
- [入力とカメラ](docs/05_入力とカメラ.md)
- [デバッグとテスト](docs/06_デバッグとテスト.md)
- [パフォーマンス](docs/07_パフォーマンス.md)
- [Gitと復元ポイント運用](docs/08_Gitと復元ポイント運用.md)
- [AI実装ワークフロー](docs/09_AI実装ワークフロー.md)
- [ぬるぬるRoll固有設計](docs/10_ぬるぬるRoll固有設計.md)
- [不具合診断表](docs/11_不具合診断表.md)
- [リリース前チェックリスト](docs/12_リリース前チェックリスト.md)

## 保護対象と次工程

コース座標、Road、`StartPad`、`CourseSpawn`、`GoalTrigger`、Baseplate退避処理は保護対象です。次工程はPhase 2の手順1「通常歩行と人工的な前進処理の停止」ですが、実装前に現在のProbe結果をStudioで確認し、物理制御方式を一つに決めます。
