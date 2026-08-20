# Symbol Shoestring Node scripts

Debian／Ubuntu系環境でSymbol Shoestring Nodeを準備、構築、保守するための
対話式シェルスクリプト群です。Nodeは構築後も自動起動しません。

## クイックスタート

Debian／Ubuntu系環境でinstallerをダウンロードします。

```bash
wget -O symbol-shoestring-installer.sh \
  https://raw.githubusercontent.com/oicoimo4/symbol-shoestring-node-quickstart/main/symbol-shoestring-installer.sh
```

ダウンロードした内容を確認してから、Bashで起動します。

```bash
less symbol-shoestring-installer.sh
bash symbol-shoestring-installer.sh
```

`less`は`q`キーで終了できます。installerは必要に応じてsudoで再実行され、
Node運用ユーザー、Docker、Docker Compose、Python環境を準備します。
`wget`がない場合は先に次を実行してください。

```bash
sudo apt-get update
sudo apt-get install -y wget
```

## スクリプトの関係

```text
symbol-shoestring-installer.sh
└─ build-symbol-shoestring-node.sh
   ├─ backup-symbol-shoestring.sh
   ├─ restore-symbol-shoestring.sh
   └─ sync-symbol-shoestring-snapshot.sh（mainnetのみ）
```

5つのシェルスクリプトは同一内容で、実行時のファイル名によって処理を
切り替えます。installerが生成する内容をGitHub上でも確認できるよう、
各ファイル名で掲載しています。

## 主な役割

| ファイル | 役割 |
|---|---|
| `symbol-shoestring-installer.sh` | ユーザー、Docker、Python環境の準備 |
| `build-symbol-shoestring-node.sh` | Shoestring Nodeの設定と構築 |
| `backup-symbol-shoestring.sh` | 設定と鍵の暗号化バックアップ |
| `restore-symbol-shoestring.sh` | 暗号化バックアップの検査と復元 |
| `sync-symbol-shoestring-snapshot.sh` | mainnet Peer snapshotの同期 |

詳しい入力内容、バックアップ対象、snapshotの注意事項は、対応する説明書を
確認してください。

## 対応環境

- DebianまたはUbuntu系OS
- Bash
- `apt-get`
- Dockerを実行できる環境
- systemd、またはDockerを起動できる`service`コマンド

Android上のTerminal環境では、Dockerデーモン、共有ストレージ、空き容量
などに環境固有の制約があります。すべてのTerminalアプリでの動作を保証する
ものではありません。

## 重要な注意

- installerはNode運用ユーザーをsudoグループへ追加します。Node運用ユーザーは
  sudoを通して管理者権限を取得できるため、アカウントと認証情報を適切に管理して
  ください。
- Node運用ユーザーはdockerグループへ追加されます。このグループは非常に
  強い権限を持ちます。
- Dockerが未導入の場合、installerはDocker公式の`get.docker.com`から
  インストールスクリプトを取得し、root権限で実行します。この処理は
  Dockerのバージョン固定や7日間の待機判定を行いません。
- Full APIとLight APIのどちらでもHTTPSを選択できます。HTTPSにはNodeを
  向いた公開ドメインと事前のDNS設定が必要です。
- HTTPでREST APIを外部公開する場合は、HTTPSとアクセス制御を別途用意して
  ください。
- mainnet snapshotは大容量です。tar.gzと展開後のdataを保持できる空き容量が
  必要です。
- snapshotは既存dataを削除してから新しいdataを直接展開します。展開中の
  容量不足、強制終了、アーカイブ異常などが発生すると、Node側のdataが
  不完全になる可能性があります。ダウンロード済みtar.gzと退避した
  harvesters.datは保持されるため、原因を解消して再実行してください。
- バックアップにブロックチェーン本体のdataとdbdata全体は含まれません。
- 秘密鍵とバックアップパスワードを公開リポジトリへ保存しないでください。

## 依存バージョンの確認

- 単体版Docker Composeとsymbol-shoestringは、公開から7日以上経過した
  リリースだけを使用します。
- 最新リリースが公開から7日未満の場合は採用せず、条件を満たす直近の
  安定版を使用します。
- 単体版Docker Composeのダウンロードは、公式リリースのSHA-256と照合します。
- 実際に使用したバージョンは`~/symbol-shoestring-versions.txt`へ記録します。
- 条件を満たす単体版Docker Composeを優先して使用します。

7日間の待機期間とSHA-256照合は、不正な改ざんや安全性に問題がないことを
完全に保証するものではありません。公開直後に判明する問題や供給網上の事故を
避けるための確認期間として設けています。

## 公開前の確認

配布するシェルスクリプトについて、構文確認とSHA-256確認を行ってください。
GitHub Actionsでも、5つのスクリプトの同一性、Bash構文、チェックサムを
自動確認します。

```bash
bash -n symbol-shoestring-installer.sh
sha256sum -c SHA256SUMS
```

## ライセンス

MIT Licenseです。詳細は`LICENSE`を確認してください。
