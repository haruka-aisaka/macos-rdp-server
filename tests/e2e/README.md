# E2E テスト（サーバ）

この Mac の中だけで、いま入っているサーバ（`~/.macos-rdp/bin/macos-rdp-daemon`）を確かめる。

```sh
brew install freerdp   # テスト用クライアントを作るためだけに使う
deno run -A tests/e2e/e2e.ts                  # 全部
deno run -A tests/e2e/e2e.ts --only audio,idle
```

- 本番の LaunchAgent（`com.macosrdp.agent`、3389）は止めない。同じバイナリを別のラベル
  `com.macosrdp.e2e` で `127.0.0.1:3390` に起動する（認証なし・`RDP_VIRTUAL_DISPLAY_KEEP=15`・
  `RDP_AUDIO_LOCAL=0`）。画面収録などの許可はバイナリの場所と署名に付いているので取り直しは要らない。
  終わったら止めて plist も消す
- 本番に接続中のクライアントがあると、仮想ディスプレイの並びを乱すので実行しない（`--force` で無視）
- 新しいビルドを試すときは、先に本番の場所へ入れる（`~/projects/mremote-installer/server.ts install`）

| テスト | 確かめること |
|---|---|
| connect | 接続して画面が届く（フレーム数・黒くない画素）。Retina の仮想ディスプレイがメインになる。ポインタが狙った点へ行く |
| resize | 表示制御チャネルで大きさ・拡大率（200% / 100%）を変えると、仮想ディスプレイとストリームが追従する |
| audio | Mac で鳴らした 997Hz の正弦波が、周波数・SN 比（35dB 超）・途切れなし・振幅で崩れずに届く |
| reconnect | きれいな切断と強制切断（クライアントを kill）のあと、同じ仮想ディスプレイを使い回してつながる。サーバは落ちない |
| takeover | 前の接続が残ったまま新しい接続が来ると、前の方が切られて新しい方に画面が届く |
| rescale | つなぎ直したときに頼んだ拡大率が反映される（Retina ⇄ 等倍、iPhone の 4K 固定 = 3840x2160@300% も） |
| idle | 放置で仮想ディスプレイを解放してプロセスが終わり、launchd が起動し直す。そのあともつながる |

## 中身

- `rdp-e2e-client.c` — 画面を持たない RDP クライアント（Homebrew の FreeRDP 3）。標準入力の命令
  （`stats`・`resize`・`mouse`・`click`・`key`・`unicode`・`shot`・`quit`）を実行し、結果を JSON で返す。
  届いた音は `--audio` のファイルへそのまま書く
- `display-probe.swift` — Mac の画面の構成（大きさ・画素数・Retina か・メインか）とポインタの位置を JSON で出す
- `e2e.ts` — 上の 2 つをビルドし、テスト用サーバを起動して順に確かめる。ログは `/tmp/rdp-e2e/`

仮想ディスプレイはベンダー番号（`0x5244500`）で見分ける。テストを始めたときにすでにあるもの
（本番のサーバが再接続のために残しているもの）は数えない。
