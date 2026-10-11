# AltStore PAL での配布

AltStore PAL は Apple 公認の代替アプリマーケットプレイス（日本・EU・ブラジル）。App Store の審査ではなく「公証（Notarization）」に通ったアプリを配れる。利用者は iOS 26.2 以上で、日本の App Store アカウントを使っている必要がある。

公開用の GitHub リポジトリ `nakajimakotaro/altstore`（public）の Releases に、source.json、アイコン、ADP（公証済みの配布パッケージ）を置く。操作はすべて `Tools/altstore.py` で行う。

- source の URL: `https://github.com/nakajimakotaro/altstore/releases/download/source/source.json`
- 追加用リンク: `altstore-pal://source?url=https://github.com/nakajimakotaro/altstore/releases/download/source/source.json`

## 最初に一度だけ

1. Apple Developer の Web サイトで、最新の Apple Developer Program 使用許諾契約に同意する（日本・EU の代替配信の条件が含まれる）
2. App Store Connect でアプリを作る（バンドル ID `jp.haru.NanpaVoice`）。アプリ名は App Store 全体で重複できない
3. App Store Connect → 右上の名前 → プロフィールを編集 で **Developer ID**（UUID。Team ID ではない）を確認し、AltStore に登録する
   ```sh
   Tools/altstore.py register --developer-id <Developer ID> --email <メールアドレス>
   ```
4. 返ってきた token を App Store Connect → ユーザとアクセス → 統合 → マーケットプレイス → ＋ に貼る。アプリを選び、通知を送る（自動で処理させる）を選ぶ
5. App Store Connect → アプリ → App 情報 の **Apple ID**（数字）を `source.json` の `marketplaceID` に入れる
6. GitHub に public リポジトリ `nakajimakotaro/altstore` を README 付きで作る（Releases にはコミットが1つ以上要る）
7. `brew install gh && gh auth login`

## リリースのたび

1. `MARKETING_VERSION`（project.yml）を必要なら上げる
2. `Tools/upload_appstore.sh` でアップロードする。`source.json` の `appPermissions` も実際の署名から書き換わるのでコミットする
3. App Store Connect → アプリ → App Review の「審査の種類」を **公証** にして提出する
4. 公証が通ったら、配信 → 履歴 で ADP ID を確認して公開する
   ```sh
   Tools/altstore.py publish --adp-id <ADP ID> --notes "更新内容"
   ```
5. 書き換わった `source.json` をコミットする

AltStore PAL は source を定期的に見に行くので、利用者には自動で更新が届く。

## 参考

- [Distribute with AltStore PAL](https://faq.altstore.io/developers/distribute-with-altstore-pal)
- [Make a Source](https://faq.altstore.io/developers/make-a-source)
- [AltStore PAL REST API](https://faq.altstore.io/developers/rest-api)
