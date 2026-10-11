# AltStore PAL での配布

AltStore PAL は Apple 公認の代替アプリマーケットプレイス（日本・EU・ブラジル）。App Store の審査ではなく「公証（Notarization）」に通ったアプリを配れる。利用者は iOS 26.2 以上で、日本の App Store アカウントを使っている必要がある。

このリポジトリ `nakajimakotaro/voicenote`（public）の Releases に、source.json、アイコン、ADP（公証済みの配布パッケージ）を置く。操作はすべて `Tools/altstore.py` で行う。

- source の URL: `https://github.com/nakajimakotaro/voicenote/releases/download/source/source.json`
- 追加用リンク: `altstore-pal://source?url=https://github.com/nakajimakotaro/voicenote/releases/download/source/source.json`

## 最初に一度だけ

1. Apple Developer の Web サイトで、最新の Apple Developer Program 使用許諾契約に同意する（日本・EU の代替配信の条件が含まれる）
2. `gh auth login` で GitHub にログインする
3. App Store Connect でアプリを作る（プラットフォーム iOS、バンドル ID `jp.haru.VoiceNote`、主言語 日本語）。名前は App Store 全体で重複できないので、「文字起こし」が使えなければ「VoiceNote 文字起こし」などにする（ホーム画面の表示名とは別でよい）
4. App Store Connect → アプリ → App 情報 の **Apple ID**（数字）を `source.json` の `marketplaceID` に入れ、`Tools/altstore.py validate` が通ることを確かめる
5. App Store Connect → 右上の名前 → プロフィールを編集 で **Developer ID**（UUID。Team ID ではない）を確認し、AltStore に登録する
   ```sh
   Tools/altstore.py register --developer-id <Developer ID> --email <メールアドレス>
   ```
6. 返ってきた token を App Store Connect → ユーザとアクセス → 統合 → マーケットプレイス → ＋ に貼る。アプリを選び、通知を送る（自動で処理させる）を選ぶ
7. App Store Connect でアプリの情報を埋める。足りないものは提出時に表示される
   - プライバシーポリシー URL: `https://github.com/nakajimakotaro/voicenote/blob/main/AltStore/PRIVACY.md`
   - App のプライバシー: 音声は利用者自身の API キーで OpenAI に送るだけで、開発者は何も集めない。迷うなら「オーディオデータ／App の機能／ユーザに紐付けない／トラッキングなし」と申告しておくと安全
   - 年齢制限の質問、カテゴリ、サポート URL（`https://github.com/nakajimakotaro/voicenote/issues` でよい）、著作権
   - スクリーンショット: iPhone 6.9 インチ（または 6.5 インチ）と iPad 13 インチ（iPad にも対応しているため）

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
