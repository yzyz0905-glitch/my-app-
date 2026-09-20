# Padlet MVP - 視覚的コラボレーション掲示板

直感的な操作でアイデアやメモ、画像を視覚的に整理・共有できるオンライン掲示板（Padlet代替）のMVP実装です。

🌐 **公開URL (GitHub Pages):**  
[https://yzyz0905-glitch.github.io/my-app-/](https://yzyz0905-glitch.github.io/my-app-/)

---

## 🎯 主な機能

### 1. 3つの表示モード（ビュー切り替え）
- 🧱 **ウォール (Wall)**: レスポンシブなグリッド形式でカードを自動整列（ピン留め優先表示）。
- 📋 **セクション (Sections / Shelf)**: カンバン方式の列レイアウト。ドラッグ＆ドロップで列間を自由に移動可能。新しいセクションの追加や削除にも対応。
- 🎨 **キャンバス (Freeform Canvas)**: カードを自由な座標にドラッグ配置できる広大なキャンバス。空いている場所をダブルクリックしてその場にカード作成可能。

### 2. リッチなカード機能
- **タイトル & 本文**: メモやアイデアの記録
- **カラーパレット**: 8種類のカラーテーマ（イエロー、ローズ、ミント、ブルー、パープル、オレンジ、ホワイト、ダーク）
- **メディア添付**: 画像URLの貼り付け、またはローカル画像のアップロード（Base64形式）＆ クリックで拡大ライトボックス表示
- **リンクブックマーク**: 外部リンクのプレビューとワンクリック移動
- **ToDoチェックリスト**: カード内でのインタラクティブなチェックリスト管理
- **タグ機能**: タグ付けと、タグクリックによるワンクリック絞り込み
- **リアクション & コメント**: いいねボタン（❤️カウント）とカード個別スレッドでのコメント機能
- **ピン留め 📌**: 重要なカードをトップに固定

### 3. ボード操作・データ管理
- **リアルタイム検索**: タイトル、内容、タグ、コメントを即座にインクリメンタル検索
- **カラーフィルター**: カードの色によるワンクリック絞り込み
- **7種類の背景テーマ**: パステル、コルクボード、ブループリント、サンセット、ミント、ダークネオン、ミニマルホワイト
- **ボード情報編集**: ボードタイトルや説明文をその場で編集
- **自動保存 (LocalStorage)**: 編集内容はブラウザ内にリアルタイム保存
- **データのエクスポート / インポート**: JSON形式でのバックアップ保存と復元
- **初期サンプル復元**: いつでも初期デモデータに戻せるリセット機能
- **リンク共有**: ボードURLをワンクリックでクリップボードへコピー

---

## ⌨️ ショートカットキー
- `Ctrl + N` / `Cmd + N`: 新規カード作成モーダルを開く
- `Esc`: モーダルや拡大画像を閉じる
- キャンバスモードでダブルクリック: その位置に新規カード作成

---

## 🚀 デプロイについて
GitHub Actions (`.github/workflows/deploy.yml`) により、`main` ブランチへのプッシュで自動的に GitHub Pages にデプロイされます。

## Supabase Phase 0

Supabaseの基盤コードは追加されていますが、現在の投稿保存・編集・削除は引き続きLocalStorageを使用します。Supabaseの設定が空の場合、匿名認証やネットワーク処理は実行されません。

### 追加ファイル


### Supabaseでやること

1. Supabaseプロジェクトを作成する。
2. AuthenticationでAnonymous Sign-Insを有効にする。
3. `supabase/schema.sql`をSQL Editorで確認して実行する。
4. `supabase_realtime`で`posts`を有効にする。
5. Project SettingsからProject URLとanon/public keyを取得する。
6. `supabase-config.js`の`url`と`anonKey`へ、公開してよい値だけを設定する。

`service_role` key、DBパスワード、JWT秘密鍵、先生パスワードはGitHub Pagesへ配置しないでください。

### 今回まだ実施していないこと


## Supabase Phase 1-A

Phase 1-Aでは、掲示板の作成・参加・参加済み一覧取得だけをオンライン対応しました。既存の投稿保存、編集、削除、表示/非表示、RealtimeはまだLocalStorage側のままです。

### 追加したRPC

- `create_board_with_owner`: `auth.uid()`で`boards.created_by`を設定し、同じユーザーを`board_members.role = 'teacher'`として登録します。
- `join_board_as_student`: URLのSupabase UUIDを対象に、現在の`auth.uid()`を`student`として登録します。
- `join_board_by_legacy_id`: 既存の`board-...`形式URLを`boards.legacy_id`で解決してstudent参加させます。

### Dashboardで追加実行すること

Phase 0適用後に更新された [supabase/schema.sql](supabase/schema.sql) 全体を、Supabase SQL Editorで再実行してください。特に上記3つのRPCと`grant execute ... to authenticated`が未適用だと、Phase 1-Aのオンライン掲示板作成・参加は動作しません。

Phase 1-Bでは`posts`のCRUDに必要な次の権限も追加しています。

- `select, insert, update, delete on public.posts to authenticated`
- これらはRLSポリシーと併用され、RLSを迂回するものではありません。

RPC適用前でも、RPCが失敗した場合は既存の掲示板作成がLocalStorageへフォールバックします。既存の`padlet_mvp_store_v1`は削除・変換しません。
