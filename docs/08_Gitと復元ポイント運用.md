# 08 Gitと復元ポイント運用

## 日常手順

```powershell
git status --short
git diff --name-only
git diff -- path/to/file
git add -- path/to/file
git diff --cached
git commit -m "message"
git push
```

`git add .` は意図しないZIP、rbxl、生成物を含める可能性があるため避け、対象pathを明示します。

## 復元ポイント

- 調査前: 現在のclean基準コミットを記録。
- 実装途中: 必要なら明確に「未確認」の作業保存。
- Studio合格後: 受入条件を満たした復元ポイント。
- commit messageは何が成立した時点かを表す。

復元ポイントはresetを自動実行する許可ではありません。戻す必要がある場合も、現変更を保護し、人間と方法を決めます。

## branch

作業開始時に `git branch --show-current` と `git log -1 --oneline` を確認します。新しいbranchは目的と統合方法が明確な場合だけ作り、現在の `main` に未保存変更がある状態で勝手に切り替えません。

## 未追跡ファイルとバイナリ

未追跡は「不要」ではありません。所有者を確認せず削除、移動、展開、コミットしません。`.rbxl`、ZIP、画像などbinaryは差分レビューしにくいため、明示的な指示がある場合だけ扱います。

現在の `Roblox_Studio_Toranomaki_Mako_Standard_v1.zip` は保護対象で、変更・展開・削除・コミットしません。

## `.gitignore`

ignore追加はファイルを削除しませんが、見え方を変えます。生成物か、共有不要か、すでにtrack済みかを確認してから別工程で変更します。

## 改行形式

WindowsではLF/CRLF warningが出る場合があります。内容変更と改行だけの変更を区別し、大量改行変換を機能変更と同じcommitに混ぜません。必要なら `.gitattributes` を別工程で設計します。

## 競合時の停止条件

- `HEAD...origin/main` が分岐している。
- remoteに未知のcommitがある。
- pushがnon-fast-forward。
- 同じfileに未確認の他者変更がある。
- Studioの正とローカルの正を判断できない。

この場合、勝手にpull、merge、rebaseしません。remote/local commitと差分を報告します。

## 通常禁止

- `git reset`: 未保存変更やindexを意図せず変える危険。
- `git clean`: 未追跡のユーザーファイルを削除する危険。
- force push: 共有履歴を上書きする危険。
- destructive checkout: 作業中変更を消す危険。

## Studio確認とcommit

静的確認だけのcommitは「Studio未確認」と記録します。物理・操作・cameraはMakoのPlay確認後に合格復元ポイントを作ります。push前にremoteとの同期、staged対象、ZIP除外を再確認します。
