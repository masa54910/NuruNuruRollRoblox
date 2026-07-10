# 02 Luauコーディング標準

## 基本方針

新規の独立Moduleは可能なら `--!strict` を検討します。ただしstrict化だけを目的に既存ファイルを全面修正しません。既存非strictコードでは、変更箇所のnil安全性と型の前提を局所的に明確にします。

## 型とnil

- 外部入力、Config、`FindFirstChild`、`WaitForChild` の結果を無条件に期待型として扱わない。
- 数値は型だけでなくNaN、無限、範囲も検証する。
- Instanceはyield後に破棄され得るため、`Parent` とCharacterの同一性を再確認する。
- 共有tableの形は型aliasまたは明確なフィールド初期値で固定する。
- `any` は境界で閉じ込め、内部へ拡散させない。

## Instance参照

- `FindFirstChild`: 存在しないことが正常、即時判定したい場合。
- `WaitForChild(name, timeout)`: 複製・生成待ちが設計上必要な場合。timeout後を処理する。
- 毎フレーム `WaitForChild` や全探索をしない。初期化時にキャッシュする。
- 名前だけでなく必要に応じて `IsA`、親階層、タグ、属性を確認する。

## task APIとイベント

- 古い `wait`、`spawn`、`delay` は追加しない。
- `task.defer`: 現在の処理後に実行。
- `task.spawn`: 独立タスク。エラーと寿命を意識する。
- `task.delay`: 遅延処理。対象がまだ有効か再確認する。
- 接続は所有者を明確にし、Character切替や終了時に `Disconnect`。
- 高頻度イベント内でconnectionを増殖させない。

## CharacterとPlayer

- `CharacterAdded` ごとにHumanoidとRootを取り直す。
- `CharacterRemoving` / deathでローカル状態を解除する。
- Serverのplayer単位tableは `PlayerRemoving` で削除する。
- 古いCharacterを参照する非同期処理は `player.Character == character` を再確認する。

## ModuleScriptとConfig

- ModuleScriptは役割を一つにし、require時の重い副作用を避ける。
- mutableな共有状態は所有者と更新APIを限定する。
- 調整値は既存 `Config` の対応セクションへ置くが、同義値を重複させない。
- feature flagは安全な初期状態、依存関係、撤去条件を記録する。

## エラーとログ

- 回復可能な不整合は `warn` と安全停止。
- 継続不能な初期化失敗は、その機能だけを停止して通常操作へ戻す。
- ログはprefix、対象、観測値、判定を含める。
- 毎フレーム出力せず、間隔制限かDebugフラグを使う。
- `pcall` は失敗を隠すためでなく、境界を安全に観測するために使う。

## 変更時チェック

- yield前後で参照は有効か。
- connection、task、tableは終了時に片付くか。
- Client/Serverのどちらで実行されるか。
- 同じ物理値や状態を書き込む別処理がないか。
- Studioでしか分からない結果を静的確認だけで断定していないか。

## 参考資料

- [Luau: An introduction to types](https://luau.org/types/)
- [Roblox Creator Hub: Scripting](https://create.roblox.com/docs/scripting)

