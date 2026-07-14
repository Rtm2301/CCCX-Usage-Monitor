# CCCX Usage Monitor

Claude Code と OpenAI Codex CLI の**利用制限の消費率**を Mac のメニューバーに常時表示し、
利用履歴をアプリ内ダッシュボードでグラフとして見られる macOS アプリです。

> **CCCX** = **CC**(Claude Code)+ **CX**(Codex)

```
メニューバー(バー表示):   ▂▂▂▂▂▂▂░░░   ← 上段: Claude 5時間セッション(オレンジ枠)
                          ▂▂▂░░░░░░░   ← 下段: Codex(白枠)
メニューバー(テキスト):   ● 74%  ○ 32%  (オレンジ● = Claude、白○ = Codex)
```

どちらの数値も **Anthropic / OpenAI のサーバーが返すアカウント全体の値**なので、
複数マシンで使っていても正確です(ローカルログの推測値ではありません)。

## 機能

- **メニューバー表示** — ミニバー2段 or 色付きドット+% のテキスト表示(切替可)。色は 緑 <60% / 黄 <85% / 赤 ≥85%、取得エラー時はオレンジ+⚠
- **ポップオーバー** — 全制限ウィンドウのゲージ、リセット予定時刻(絶対時刻+残り時間)、プラン表示(例: `Claude plan: max 5x ・ Codex plan: plus`)、各種設定
- **ダッシュボード**
  - **制限消費率**: 5時間セッション枠を点線の箱+面グラフで表示(Usage for Claude 風)。ホバーで「開始→終了・ピーク%・上限到達までの時間」。週次などの他ウィンドウは折れ線で重ね描き。Claude/Codex 切替、期間 12h〜90d、CSV 書き出し、グラフ下にリセット予定時刻
  - **インサイト**: セッション上限到達回数(平均到達時間)・平均週次使用率・高負荷(90%+)日数を Claude / Codex の2段組で
- **フローティングHUD** — 常に最前面の半透明パネル(全Space・フルスクリーン上でも表示、ドラッグで移動、位置記憶)
- **自動判定** — Claude Code 未ログイン / codex 未インストールの環境では、そのサービスの表示を自動で隠します(エラーにしない)。後からセットアップすれば再起動なしで現れます
- **1分同期** — 両サービスとも60秒ごとに更新(間隔は 1/2/5分 で変更可)。429 時は `Retry-After` を尊重して指数バックオフ

## 必要環境

- macOS 14 (Sonoma) 以降、Apple Silicon
- Xcode Command Line Tools(Swift 6 系。`xcode-select --install` で導入)
- 監視対象(**どちらか片方だけでも動きます**):
  - [Claude Code](https://claude.com/claude-code) にログイン済み(サブスクリプション認証)
  - [Codex CLI](https://developers.openai.com/codex/cli) にログイン済み(ChatGPT 認証)

## ビルドとインストール

```bash
git clone https://github.com/Rtm2301/CCCX-Usage-Monitor.git
cd CCCX-Usage-Monitor
Scripts/build-app.sh --install   # ビルドして /Applications にインストール
open "/Applications/CCCX Usage Monitor.app"
```

- `--install` なしなら `dist/CCCX Usage Monitor.app` に出力されます
- SPM ではなく swiftc 直接コンパイルです(外部依存ゼロ。`swift build` は不要)
- ログイン時に自動起動するには: システム設定 → 一般 → ログイン項目 に `CCCX Usage Monitor.app` を追加
- 内部名(実行バイナリ・データフォルダ)は歴史的経緯で `UsageBar` のままです(`~/Library/Application Support/UsageBar/`)

### 初回起動時の許可

Claude Code の OAuth トークンを読むため、初回に **Keychain のアクセス許可ダイアログ**が1回出ます。
「**常に許可**」を選んでください(Apple 署名済みの `/usr/bin/security` 経由なので、アプリを再ビルドしても許可は持続します)。

## 仕組み(データソース)

| データ | 取得方法 | 精度 |
|---|---|---|
| Claude 制限%(セッション/週次/モデル別) | Keychain のサービス `Claude Code-credentials` から OAuth トークンを読み、`GET https://api.anthropic.com/api/oauth/usage`(ヘッダ `anthropic-beta: oauth-2025-04-20`)。レスポンスの `limits[]` 配列をデコード | **アカウント全体・ライブ** |
| Claude プラン | 同 Keychain の `subscriptionType` + `rateLimitTier` | — |
| Codex 制限% | `codex app-server` を子プロセスとして常駐させ、JSON-RPC `account/rateLimits/read` を毎分呼ぶ。app-server 不可時は `~/.codex/sessions/**/rollout-*.jsonl` の最終値にフォールバック(黄バナーで明示) | **アカウント全体・ライブ** |
| 制限%の推移グラフ | 上記を毎分記録した自前の蓄積(`snapshots/YYYY-MM.jsonl`、90日保持)。API は現在値しか返さないため、**履歴はアプリ稼働中のみ**蓄積されます | アカウント全体 |

トークン数や金額ベースの表示は意図的にありません。API は使用率%しか返さず、トークン/コストを
アカウント全体で正確に出す方法が存在しないためです(ローカルログ集計だと「このMacの分だけ」になり誤解を招く)。

- リセット時刻は常にサーバー返却の `resets_at` をそのまま表示します(自前で予測しないため、障害後の臨時リセットや72時間週次リセットなどの不規則な変更にも1分以内に追従します)
- `api/oauth/usage` は**非公開エンドポイント**です。Anthropic 側の変更で動かなくなる可能性があり、その場合は最後の正常値+⚠表示に退避します

## データとカスタマイズ

すべて `~/Library/Application Support/UsageBar/` 以下:

| ファイル | 内容 |
|---|---|
| `snapshots/YYYY-MM.jsonl` | 制限%の1分ごとの記録(値が変わった時のみ追記、3ヶ月で自動削除) |

テスト・デバッグ用の環境変数:
`USAGEBAR_KEYCHAIN_SERVICE`(Keychainサービス名の差し替え) / `USAGEBAR_CODEX_DIR` / `USAGEBAR_CODEX_BIN` / `USAGEBAR_DATA_DIR` / `USAGEBAR_FAKE_401=1`(トークン期限切れの再現)

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `● —⚠` が出続ける | Claude Code に一度ログインし直す(トークンは Claude Code 自身が更新します)。ポップオーバーのバナーに理由が出ます |
| Codex が黄バナー(フォールバック) | GUI アプリの PATH に codex が無いケースは対応済み(`/opt/homebrew/bin` 等を自動探索)。それでも出る場合は `USAGEBAR_CODEX_BIN=/path/to/codex` を指定 |
| 429(レート制限)が頻発 | 他の使用量監視アプリ(Usage for Claude 等)との併用で合算頻度が上がっています。どちらかを止めるか、ポップオーバーで更新間隔を2〜5分に |
| ビルドで SDK 不整合エラー | Command Line Tools が壊れています: `sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install` |
| アプリのアイコンが変わらない | `killall Finder` または再ログイン(アイコンキャッシュ) |

## プロジェクト構成

```
Package.swift                     # (参考) SPM定義 — ビルドは Scripts/build-app.sh が正
Support/Info.plist                # LSUIElement=true(Dockに出ない常駐アプリ)
Support/UsageBar.icns             # アプリアイコン(make-icon.sh で生成)
Scripts/build-app.sh              # swiftc → .app 組み立て → ad-hoc 署名 → (--install)
Scripts/make-icon.sh              # PNG → .icns
Sources/UsageBar/
  UsageBarApp.swift               # @main: MenuBarExtra + Dashboard Window
  AppState.swift                  # 中枢: ポーリング、状態、履歴、未設定判定
  Models/                         # LimitSnapshot(seriesKey方式) / HourBucket / 価格
  Services/
    ClaudeAuth.swift              # Keychain → トークン+プラン
    ClaudeLimitsClient.swift      # oauth/usage(429バックオフ、防御的デコード)
    CodexAppServerClient.swift    # codex app-server 常駐 JSON-RPC クライアント
    CodexLimitsReader.swift       # rollout ファイルのフォールバック読み取り
    SnapshotStore.swift           # 制限スナップショットの JSONL 永続化
  Views/                          # ポップオーバー / メニューバー描画 / HUD / 各チャート
```

## 制限事項

- 制限%の**推移**はアプリが動いている間しか記録されません(APIが現在値のみ返すため)
- ad-hoc 署名なので配布には向きません(各自がローカルでビルドする前提)。Gatekeeper 警告を避けたい場合は自分の Developer ID で `codesign` してください
