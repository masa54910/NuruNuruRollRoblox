# ぬるぬるRoll 常設開発ルール

このリポジトリでCodexが行うすべての作業に適用します。

## 作業開始前

1. `README.md`、`IMPLEMENTATION_PLAN.md`、`STATUS.md`、`docs/10_ぬるぬるRoll固有設計.md`、作業に関係するdocsを読む。
2. 現状コードを全文検索・確認してから変更する。
3. 調査する原因または実装目的を一文で示す。
4. 変更対象と変更禁止対象を先に列挙する。
5. `git status --short` を確認し、既存変更と未追跡ファイルを保護する。
6. ローカル、Rojo同期中のStudio、StudioだけのInstanceのどれが正か確認する。

## 変更ルール

- 一度に一工程だけ、仮説を検証できる最小差分で変更する。
- 指示対象外のリファクタ、改名、整形、ファイル移動をしない。
- 局所修正で済む場合にファイル全体を書き換えない。
- 未コミット変更を破棄しない。`git reset`、`git clean`、force push、破壊的checkoutは禁止。
- Roblox Creator Hub、Luau、Rojoの現行公式仕様と、本プロジェクトの確認済み仕様を優先する。
- Clientの入力・表示と、Serverの正当性・検証を分離する。
- Client発RemoteはServerで型、有限性、範囲、頻度、権限、距離、状態を検証する。
- Character再生成とPlayer退出時にイベント、task、参照を後始末する。
- 毎frame処理とWorkspace全探索を必要最小限にする。
- 古い `wait`、`spawn`、`delay` を追加しない。

## ぬるぬるRollの保護対象

- 明示的なコース作業でない限り、既存コースと `MapBuilder.server.lua` を変更しない。
- コース座標、Road位置、`StartPad`、`CourseSpawn`、`GoalTrigger` を変更しない。
- Baseplateをコースへ戻さず、退避・非衝突・非接触・非Query・透明状態を維持する。
- Legacy機能は削除せず、Configフラグ停止を維持する。
- Phase 2で `VehicleSeat` を使用しない。
- プレイヤー移動にCFrameやTweenを使用しない。
- `HumanoidRootPart` を物理主体とするが、主制御方式はStudioで検証してから採用する。
- Roblox Studioで未確認の挙動を完成扱いにしない。
- 表示タイトルは「ぬるぬるHill ～街中ダウンヒル～」。内部project名や既存識別子は明示的な移行工程なしに改名しない。

## 確認と報告

1. 差分を確認し、対象外fileが変わっていないことを確認する。
2. 静的確認と、必要に応じてRojo sourcemap生成を行う。
3. StudioのScript AnalysisとOutputを確認する。
4. Play、必要に応じてServer & Clientsで確認する。
5. 静的確認、Studio確認、未確認を明確に分ける。
6. 変更file、確認結果、残課題、戻し先commitを報告する。
7. 合格後に対象fileだけで復元ポイントを作る。
8. 見た目、操作感、物理など人間の判断が必要な段階で止める。

詳細は[AI実装ワークフロー](docs/09_AI実装ワークフロー.md)と[固有設計](docs/10_ぬるぬるRoll固有設計.md)を参照します。
