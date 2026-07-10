# 01 StudioとRojo運用

## 三つの状態を混同しない

- ローカルソース: Gitで保存するLuauと文書。
- Studio DataModel: Play時に実際に実行されるInstance。
- `.rbxl`: Studio側のplace保存。Rojo管理外Instanceを含み得る。

Rojo接続中はproject treeに対応するローカル内容がStudioへ反映されます。Studio側だけで同期対象Scriptを編集すると、再接続や再同期で消える可能性があります。

## `default.project.json`

現在は `ReplicatedStorage`、`ServerScriptService`、`StarterPlayer` に `$path` が設定されています。`emitLegacyScripts` は `false` です。既定のRojo serve portは34872で、現ファイルには別ポート指定がありません。

## 安全な接続手順

1. 正しいリポジトリとbranch、`git status --short` を確認。
2. Studioで対象 `.rbxl` を開く。
3. プロジェクトルートで `rojo serve default.project.json`。
4. Rojoプラグインから `localhost:34872` に接続。
5. 接続先project名が `NuruNuruRollRoblox` であることを確認。
6. Explorerで主要ServiceとScript名をローカル構成と照合。
7. Outputに二重MapBuilderなど予期しない起動がないことを確認。

## 同期で上書きされる範囲

`$path` 配下は原則ローカルを正とします。WorkspaceはServiceだけ定義され `$path` がないため、place内のBaseplateなどは別管理です。ただしServer ScriptがPlay中にWorkspaceを生成・変更することがあります。Edit状態とPlay状態も区別してください。

## よくあるトラブル

| 症状 | 確認 |
| --- | --- |
| Studio編集が消えた | そのInstanceがRojo `$path` 配下か |
| ローカル変更が出ない | 接続先、serve中のフォルダ、同名Script重複 |
| 古い処理が走る | Studio内にRojo管理外の旧Scriptが残っていないか |
| Mapが二重生成 | Script full name、起動回数、Workspaceの同名Root数 |
| 接続後に大量削除表示 | project treeと接続先placeが正しいか。適用せず停止 |

## 安全な復旧

1. Playを停止し、Git差分とStudioの未保存変更を記録。
2. Rojo接続先とローカルパスを再確認。
3. 削除やresetをせず、どちらの状態を残すべきか決める。
4. 必要なら `.rbxl` の複製とGit復元ポイントを作る。
5. 小さい対象で再接続し、ExplorerとOutputを確認。

## 確認コマンド

```powershell
git status --short
rojo sourcemap default.project.json -o sourcemap.json
rojo serve default.project.json
```

## 参考資料

- [Rojo 7: Project Format](https://rojo.space/docs/v7/project-format/)
- [Roblox Creator Hub: Script Editor and Script Analysis](https://create.roblox.com/docs/studio/script-editor)

