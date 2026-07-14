[English](README.md) | **日本語**

# jind-ai-notifier

[jind-ai](https://github.com/takaaki-s/jind-ai)（`jin`）の通知プラグインです。
同時に、jind-ai のプラグイン機構の公式 example も兼ねています — マニフェスト 1
本、シェルスクリプト 1 本、ビルド不要です。

## できること

- **セッションごとに未対応の通知を最新 1 件だけ**保持します。同じセッションに新し
  い通知が来ると古いものを上書きし、履歴は溜め込みません。
- ストックする種別は **タスク完了**（done）と **許可要求**（permission）の 2 つだ
  けです。エラーは対象外です。
- セッションが **thinking**（誰かが対応中）に戻ると、そのエントリを自動的に消化し
  ます — 一覧の意味は常に「まだ人の対応を待っているセッション」です。
- キーバインドで **未対応セッションの一覧** を tmux ポップアップに表示します。選択
  するとそのセッションへ切り替わり、エントリが消化されます。一覧を眺めただけでは何
  も消えません。
- 各イベントでは **デスクトップ通知** も発行します。クリックするとそのセッションへ
  直接切り替わります。

## 必要要件

- **jin（jind-ai）** — [PR #63](https://github.com/takaaki-s/jind-ai/pull/63)
  の v1.x プラグイン拡張を含む `main`、すなわち次リリース以降。本プラグインは
  `jin pane popup --here`、`jin session focus`、`JIN_NOTIFY_KIND` / caller-tmux
  環境変数に依存します。
- **bash 4+**
- **flock**（util-linux） — ストックファイルへの書き込みを直列化します。コマンドが
  存在しない環境（素の macOS 等）でも動作しますが、ロックなしで更新し stderr に警告を
  出します — `brew install flock` で直列化が有効になります。一次対象は Linux で、
  macOS は best-effort です。
- **Linux**: クリックでの切り替えには、`notify-send` と **action 対応の** 通知
  デーモン（dunst / mako / GNOME Shell など）が必要です。

任意:

- **fzf** — より快適な、絞り込み可能な一覧 UI になります。なければポップアップは番
  号入力にフォールバックします。
- **macOS**: `terminal-notifier` — クリックでの切り替えを有効にします（best-effort）。
  なくても通常の通知は表示されます。

## インストール

jin プラグインレジストリ経由（レジストリエントリの SHA でピン留めされます）:

```bash
jin plugin install jind-ai-notifier
```

または git URL 指定で直接:

```bash
jin plugin install github.com/takaaki-s/jind-ai-notifier
```

いずれの経路でも、jind-ai はプラグインをマニフェストの `name:` フィールドが示す
ディレクトリ — `jind-ai-notifier` — の下にインストールし、この名前がそのまま
`jin plugin run` に渡す動詞にもなります。以下のコマンドはすべて
`jind-ai-notifier` を使います（例: `jin plugin run jind-ai-notifier`）。

開発時は、ローカルの作業ディレクトリをシンボリックリンクで配置します:

```bash
jin plugin install --link .
```

## 使い方

普段使いの（外側の）tmux にキーバインドを設定して一覧を開きます:

```tmux
bind-key N run-shell "jin plugin run jind-ai-notifier"
```

ポップアップの操作:

- **enter** — 選択したセッションへ切り替える（エントリを消化する）。
- **esc / q** — 何も変更せずに閉じる（fzf では `esc`、番号入力では `q`）。

fzf があれば一覧を絞り込み検索できます。なければ行番号を入力して enter を押します。

一覧の見方 — 1 行 = 1 セッション、新しい順:

- `✓ done`（緑） — タスク完了。行には最終アシスタントメッセージの断片も表示されます。
- `⏸ wait`（黄） — 許可待ち。

削除・kill 済みのセッションは、一覧を開いた時点で自動的に取り除かれます。デスクトッ
プ通知をクリックすると、ポップアップを開かずにそのセッションへ直接切り替わります。

## カスタマイズ

### ポップアップサイズ

このプラグインは `jind-ai-plugin.yaml` で `popup: { width: 70, height: 60 }` を宣言
しており、デフォルトでは端末の 70% × 60% を占めます。異なるサイズにしたい場合は
`jin` の config で `popups.plugins.jind-ai-notifier` に上書きを書いてください（各値は端末に
対する 1–100 のパーセント）:

```yaml
# ~/.config/jind-ai/config.yaml
popups:
  plugins:
    jind-ai-notifier:
      width: 80
      height: 50
```

ユーザ config が manifest のデフォルトよりも優先されます。解決チェーンの詳細は
jin の [Popup Sizes ガイド](https://github.com/takaaki-s/jind-ai/blob/main/docs/tui-guide.md#popup-sizes)
を参照。

## 状態 / ファイル

ストックの置き場所:

```
~/.local/state/jind-ai-notifier/stock.tsv
```

（パスは固定です: プラグインプロセスは `XDG_STATE_HOME` を剥がした許可リスト環境で
実行されます。）中身は 1 行 = 1 セッションの素の TSV です。すべて消したい場合は削除
するだけで構いません — 次のイベントで再生成されます:

```bash
rm ~/.local/state/jind-ai-notifier/stock.tsv
```

## 既知の事項

- jind-ai の **内蔵** デスクトップ通知も発行されるため、各通知が二重に表示されます。
  内蔵の通知機能は将来削除予定であり、本プラグイン側では抑制しません。

## example として

このリポジトリは jind-ai のプラグイン機構のリファレンス example です。すべては
[`notifier.sh`](notifier.sh) に収まっています。自分のプラグインに取り入れる価値のあ
る作法をいくつか挙げます:

- **1 マニフェストで 2 系統のトリガー。** `main()` が `JIN_EVENT` で分岐します:
  `status_changed` はイベントリスナー（`mode_listener`）を、`action`（`jin plugin
  run` 由来）はポップアップ（`mode_action`）を実行します。2 本目のスクリプトはあり
  ません。
- **ポップアップは `JIN_*` を継承しない。** tmux はポップアッププロセスを新規に起動
  するため、`mode_action` は必要な値をすべてコマンドラインで渡します: env 代入プレ
  フィックス（`env JIN_BIN=... JIN_SOCKET=...`）と、内側コマンド全体を **単一トーク
  ン** にまとめる `printf '%q '` です — `jin pane popup -- ...` は末尾引数を空白で再
  結合するため、そのままではパスが壊れます。
- **jin へは常に `"${JIN_BIN:-jin}"` で呼び戻す。** `PATH` 上の `jin` は、dispatch
  したデーモンより古い可能性があります（`JIN` はスクリプト冒頭で一度だけ解決します）。
- **あらゆる場所で fail-open。** 5 秒以内に取れなかったロック（`with_lock`）、存在し
  ない `notify-send`（`desktop_notify`）、死んだセッション — いずれも stderr にログ
  して 0 を返します。通知 1 件のためにセッションのステータスパイプラインを止める価値
  はありません。
- **状態はプラグインディレクトリの外に置く。** プラグインディレクトリではなく
  `~/.local/state/...` です: `jin plugin update` はディレクトリを丸ごと差し替えます
  し、そもそもプラグインの許可リスト環境は `XDG_STATE_HOME` を剥がします
  （`STATE_DIR` の上のコメントを参照）。

## 開発

テストは bats-core と shellcheck を使います。テストフレームワークは必要時に vendoring
します（CI と開発者が clone するもので、コミットはしません）。

```bash
# lint
shellcheck notifier.sh test/stubs/jin

# テスト: bats-core を一度 clone してから実行
git clone --depth 1 https://github.com/bats-core/bats-core.git test/lib/bats-core
test/lib/bats-core/bin/bats test
```

テストは `JIN_BIN` をスタブ（`test/stubs/jin`）に向けるため、リスナー / 消化のフロー
全体をデーモンなしで実行できます — これ自体が `"${JIN_BIN:-jin}"` 契約の実演になって
います。CI（[`.github/workflows/ci.yml`](.github/workflows/ci.yml)）は ubuntu-latest
上でこの 2 ステップをそのまま実行します。

## ライセンス

MIT。[LICENSE](LICENSE) を参照してください。
