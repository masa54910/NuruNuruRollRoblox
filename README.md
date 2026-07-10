# ぬるぬるRoll (Roblox)

Rojo 7.x 用の初期プロジェクトです。

MVP は「巨大な石畳坂をローションで滑走し、港から海へダイブする」体験を最優先にしています。

## 構成

- `default.project.json`
- `src/ReplicatedStorage`
- `src/ServerScriptService`
- `src/StarterPlayer`

## 使い方

1. Roblox Studio を開く
2. Rojo プラグインを有効化
3. プロジェクトルートで以下を実行

```powershell
rojo serve
```

4. Studio 側で Rojo プラグインから `localhost` に接続

## 補足

- この構成は DataModel の標準サービス名に合わせた初期設定です。
- ソースは `src` 以下に追加していきます。

## 現在のMVP実装

- 巨大な下り坂コース生成（カーブ、軽いアップダウン、上り返し、港への大下り、海ダイブ）
- 石畳道路 + ローション面の重ね配置
- ゴール判定、スコア加算、ラウンド進行、リザルト通知
- クライアントHUD（ラウンド状態・速度・結果表示）

## Creator Store素材の導入方法

建物や街オブジェクトは、Roblox Studio の Toolbox から取得したモデルを
`ServerStorage/CreatorStorePrefabs` に配置してください。

`MapBuilder.server.lua` はこのフォルダにあるモデルをコース左右へ配置します。
フォルダが空の場合は、白ブロック/色付きPartの簡易ファサードで自動生成します。
