#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_PATH="$(readlink -f "$0")"
TARGET_USER=""
TARGET_HOME=""
VENV_DIR=""
NODE_DIR=""
NETWORK_NAME=""
NETWORK_PACKAGE=""
NODE_FEATURES="PEER|HARVESTER"
LIGHT_API_ENABLED="false"
API_HTTPS_ENABLED="false"
NODE_HOST=""
FRIENDLY_NAME=""
BENEFICIARY_ADDRESS=""
INSTALL_DIR=""
CONFIG_DIR=""
CA_KEY_PATH=""
NODE_KEY_PATH=""
HARVESTER_IMPORT_PATH=""
ACCOUNT_SETUP_MODE="auto"
GENERATED_BUILD_PATH=""
GENERATED_BACKUP_PATH=""
GENERATED_RESTORE_PATH=""
GENERATED_SNAPSHOT_PATH=""
BACKUP_TEMP_ARCHIVE=""
RESTORE_TEMP_ARCHIVE=""
SNAPSHOT_WORK_DIR=""

info() {
  printf '\n[INFO] %s\n' "$*"
}

warn() {
  printf '\n[WARN] %s\n' "$*" >&2
}

die() {
  printf '\n[ERROR] %s\n' "$*" >&2
  exit 1
}

confirm() {
  local prompt="$1"
  local default="${2:-N}"
  local answer

  while true; do
    if [[ "$default" == "Y" ]]; then
      read -r -p "$prompt [Y/n]: " answer
      answer="${answer:-Y}"
    else
      read -r -p "$prompt [y/N]: " answer
      answer="${answer:-N}"
    fi

    case "$answer" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
      *) printf 'y または n を入力してください。\n' ;;
    esac
  done
}

run_as_target() {
  if [[ "$(id -un)" == "$TARGET_USER" ]]; then
    "$@"
  else
    sudo -H -u "$TARGET_USER" -- "$@"
  fi
}

on_error() {
  local exit_code=$?
  printf '\n[ERROR] %s の処理中にエラーが発生しました（行: %s、終了コード: %s）。\n' \
    "$SCRIPT_NAME" "${BASH_LINENO[0]}" "$exit_code" >&2
  printf '問題を修正後、同じスクリプトを再実行できます。\n' >&2
  exit "$exit_code"
}
trap on_error ERR

self_elevate() {
  if [[ $EUID -eq 0 ]]; then
    return
  fi

  command -v sudo >/dev/null 2>&1 \
    || die "sudoが見つかりません。rootで $SCRIPT_PATH を実行してください。"

  info "セットアップに管理者権限が必要なため、sudoへ切り替えます。"
  exec sudo -- bash "$SCRIPT_PATH" "$@"
}

check_platform() {
  [[ -r /etc/os-release ]] || die "/etc/os-release が見つかりません。Debian/Ubuntu系OSが必要です。"

  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *)
      case " ${ID_LIKE:-} " in
        *" debian "*) ;;
        *) die "対応対象はDebian/Ubuntu系です（検出: ${ID:-不明}）。" ;;
      esac
      ;;
  esac

  command -v apt-get >/dev/null || die "apt-get が見つかりません。"
  info "OS: ${PRETTY_NAME:-${ID}} / アーキテクチャ: $(uname -m)"
}

select_user() {
  local suggested_user="symbolnode"

  while true; do
    read -r -p "ノード運用ユーザー名 [${suggested_user}]: " TARGET_USER
    TARGET_USER="${TARGET_USER:-$suggested_user}"

    if [[ ! "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      warn "ユーザー名には小文字英数字、_、-を使用してください。"
      continue
    fi
    [[ "$TARGET_USER" != "root" ]] || { warn "root以外を指定してください。"; continue; }
    break
  done

  if id "$TARGET_USER" >/dev/null 2>&1; then
    confirm "既存ユーザー '$TARGET_USER' を再利用しますか？" Y \
      || die "別のユーザー名で再実行してください。"
  else
    info "ユーザー '$TARGET_USER' を作成します。パスワードを2回入力してください。"
    adduser --gecos "" "$TARGET_USER"
  fi

  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] \
    || die "ユーザー '$TARGET_USER' のホームディレクトリを確認できません。"

  if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx sudo; then
    info "'$TARGET_USER' は既にsudoグループに所属しています。"
  else
    gpasswd -a "$TARGET_USER" sudo
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    info "Dockerは既にインストールされています: $(docker --version)"
  else
    apt-get update
    apt-get install -y ca-certificates curl
    curl -fsSL https://get.docker.com | sh
  fi

  if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
    info "'$TARGET_USER' は既にdockerグループに所属しています。"
  else
    usermod -aG docker "$TARGET_USER"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl start docker
    systemctl enable docker
  elif command -v service >/dev/null 2>&1; then
    service docker start
    warn "systemdがないため、Dockerの自動起動設定は行っていません。"
  elif ! docker info >/dev/null 2>&1; then
    die "Dockerデーモンを起動できません。環境に応じた方法で起動してください。"
  fi
  docker --version
}

install_docker_compose() {
  local version
  local os
  local arch
  local download_url
  local checksum_url
  local expected_checksum
  local actual_checksum
  local current_version=""
  local download_file=""
  local checksum_file=""
  local releases_file=""

  if [[ -x /usr/local/bin/docker-compose ]]; then
    current_version="$(/usr/local/bin/docker-compose version --short 2>/dev/null || true)"
  fi

  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  releases_file="$(mktemp --tmpdir docker-compose-releases.XXXXXX)"
  if ! curl -fsSL 'https://api.github.com/repos/docker/compose/releases?per_page=100' -o "$releases_file"; then
    rm -f -- "$releases_file"
    die "Docker Composeのリリース情報を取得できませんでした。"
  fi
  version="$(python3 - "$releases_file" "$os" "$arch" <<'PY'
import datetime
import json
import sys

filename, os_name, architecture = sys.argv[1:]
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=7)
binary_name = f'docker-compose-{os_name}-{architecture}'
checksum_name = f'{binary_name}.sha256'

with open(filename, encoding='utf-8') as infile:
    releases = json.load(infile)

candidates = []
for release in releases:
    if release.get('draft') or release.get('prerelease'):
        continue
    published = release.get('published_at')
    if not published:
        continue
    published_at = datetime.datetime.fromisoformat(published.replace('Z', '+00:00'))
    asset_names = {asset.get('name') for asset in release.get('assets', [])}
    if published_at <= cutoff and {binary_name, checksum_name} <= asset_names:
        candidates.append((published_at, release.get('tag_name', '')))

if candidates:
    print(max(candidates)[1])
PY
)"
  rm -f -- "$releases_file"
  [[ -n "$version" ]] || die "公開から7日以上経過したDocker Composeを確認できませんでした。"

  download_url="https://github.com/docker/compose/releases/download/${version}/docker-compose-${os}-${arch}"
  checksum_url="${download_url}.sha256"
  checksum_file="$(mktemp --tmpdir docker-compose-checksum.XXXXXX)"
  if ! curl -fL "$checksum_url" -o "$checksum_file"; then
    rm -f -- "$checksum_file"
    die "Docker ComposeのSHA-256ファイル取得に失敗しました。"
  fi
  read -r expected_checksum _ <"$checksum_file"
  [[ "$expected_checksum" =~ ^[[:xdigit:]]{64}$ ]] || {
    rm -f -- "$checksum_file"
    die "Docker ComposeのSHA-256ファイル形式が不正です。"
  }

  if [[ -x /usr/local/bin/docker-compose && "${current_version#v}" == "${version#v}" ]]; then
    actual_checksum="$(sha256sum /usr/local/bin/docker-compose | cut -d' ' -f1)"
    if [[ "${actual_checksum,,}" == "${expected_checksum,,}" ]]; then
      rm -f -- "$checksum_file"
      info "公開から7日以上経過したDocker Composeを確認済みです: $version"
      return
    fi
    warn "既存のDocker ComposeはSHA-256が一致しないため再取得します。"
  fi

  info "公開から7日以上経過したDocker Compose ${version} を取得します。"
  download_file="$(mktemp --tmpdir docker-compose.XXXXXX)"
  if ! curl -fL "$download_url" -o "$download_file"; then
    rm -f -- "$download_file" "$checksum_file"
    die "Docker Composeの取得に失敗しました。"
  fi
  actual_checksum="$(sha256sum "$download_file" | cut -d' ' -f1)"
  [[ "${actual_checksum,,}" == "${expected_checksum,,}" ]] || {
    rm -f -- "$download_file" "$checksum_file"
    die "Docker ComposeのSHA-256が一致しません。インストールを中止します。"
  }
  install -m 755 "$download_file" /usr/local/bin/docker-compose
  rm -f -- "$download_file" "$checksum_file"
  /usr/local/bin/docker-compose version
}

install_shoestring_dependencies() {
  local py_version
  local versioned_venv_package

  info "ShoestringとPython仮想環境に必要なパッケージを確認します。"
  apt-get update
  apt-get install -y libssl-dev build-essential python3-dev python3-pip

  py_version="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  versioned_venv_package="python${py_version}-venv"

  if apt-cache show "$versioned_venv_package" >/dev/null 2>&1; then
    apt-get install -y "$versioned_venv_package"
  else
    warn "${versioned_venv_package} が見つからないため、python3-venvを使用します。"
    apt-get install -y python3-venv
  fi
}

prepare_virtualenv() {
  local versions_file="${TARGET_HOME}/symbol-shoestring-versions.txt"
  local compose_version
  local shoestring_version
  local selected_shoestring_version
  local releases_file

  VENV_DIR="${TARGET_HOME}/env"

  if [[ -x "${VENV_DIR}/bin/python3" ]]; then
    confirm "既存の仮想環境 '${VENV_DIR}' を再利用しますか？" Y \
      || die "既存環境は削除していません。別名対応は実装前に相談してください。"
  elif [[ -e "$VENV_DIR" ]]; then
    die "${VENV_DIR} は存在しますがPython仮想環境ではありません。内容を確認してください。"
  else
    run_as_target python3 -m venv "$VENV_DIR"
  fi

  releases_file="$(mktemp --tmpdir symbol-shoestring-releases.XXXXXX)"
  if ! curl -fsSL https://pypi.org/pypi/symbol-shoestring/json -o "$releases_file"; then
    rm -f -- "$releases_file"
    die "symbol-shoestringのリリース情報を取得できませんでした。"
  fi
  selected_shoestring_version="$("${VENV_DIR}/bin/python3" - "$releases_file" <<'PY'
import datetime
import json
import re
import sys

cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=7)
with open(sys.argv[1], encoding='utf-8') as infile:
    releases = json.load(infile).get('releases', {})

candidates = []
for version, files in releases.items():
    if re.search(r'(?:a|b|rc|dev)\d*', version, re.IGNORECASE):
        continue
    active_files = [item for item in files if not item.get('yanked') and item.get('upload_time_iso_8601')]
    if not active_files:
        continue
    newest_upload = max(datetime.datetime.fromisoformat(
        item['upload_time_iso_8601'].replace('Z', '+00:00')) for item in active_files)
    if newest_upload <= cutoff:
        candidates.append((newest_upload, version))

if candidates:
    print(max(candidates)[1])
PY
)"
  rm -f -- "$releases_file"
  [[ -n "$selected_shoestring_version" ]] \
    || die "公開から7日以上経過したsymbol-shoestringを確認できませんでした。"

  info "公開から7日以上経過したsymbol-shoestring ${selected_shoestring_version}をインストールします。"
  run_as_target "${VENV_DIR}/bin/python3" -m pip install --upgrade \
    "symbol-shoestring==${selected_shoestring_version}"

  info "Shoestringのインストールを確認します。"
  run_as_target "${VENV_DIR}/bin/python3" -m shoestring --help >/dev/null
  run_as_target "${VENV_DIR}/bin/python3" -m pip show symbol-shoestring \
    | sed -n '/^Name:/p;/^Version:/p;/^Location:/p'

  if command -v docker-compose >/dev/null 2>&1; then
    compose_version="$(docker-compose version --short 2>/dev/null || docker-compose version)"
  else
    compose_version="$(docker compose version --short 2>/dev/null || docker compose version)"
  fi
  shoestring_version="$(run_as_target "${VENV_DIR}/bin/python3" -m pip show symbol-shoestring \
    | sed -n 's/^Version:[[:space:]]*//p')"
  run_as_target "${VENV_DIR}/bin/python3" - "$versions_file" "$compose_version" "$shoestring_version" <<'PY'
import datetime
import os
import sys

filename, compose_version, shoestring_version = sys.argv[1:]
with open(filename, 'w', encoding='utf-8') as outfile:
    outfile.write(f'checked_utc={datetime.datetime.now(datetime.timezone.utc).isoformat()}\n')
    outfile.write(f'docker_compose={compose_version}\n')
    outfile.write(f'symbol_shoestring={shoestring_version}\n')
os.chmod(filename, 0o600)
PY
  info "使用バージョンを記録しました: $versions_file"
}

prepare_node_directory() {
  NODE_DIR="${TARGET_HOME}/symbolNode"

  if [[ -d "$NODE_DIR" ]]; then
    confirm "既存の作業ディレクトリ '${NODE_DIR}' を再利用しますか？" Y \
      || die "既存ディレクトリは変更していません。"
  elif [[ -e "$NODE_DIR" ]]; then
    die "${NODE_DIR} はディレクトリではありません。"
  else
    run_as_target mkdir "$NODE_DIR"
  fi
}

select_network() {
  local choice
  local confirmation

  while true; do
    read -r -p "ネットワークを選択してください [1=testnet / 2=mainnet、既定: 1]: " choice
    choice="${choice:-1}"

    case "$choice" in
      1|testnet)
        NETWORK_NAME="testnet"
        NETWORK_PACKAGE="sai"
        break
        ;;
      2|mainnet)
        read -r -p "mainnetを構築する場合は mainnet と入力してください: " confirmation
        [[ "$confirmation" == "mainnet" ]] \
          || { warn "mainnetの確認が一致しません。もう一度選択してください。"; continue; }
        NETWORK_NAME="mainnet"
        NETWORK_PACKAGE="mainnet"
        break
        ;;
      *) warn "1、2、testnet、mainnetのいずれかを入力してください。" ;;
    esac
  done
}

feature_enabled() {
  local feature="$1"

  [[ "|${NODE_FEATURES}|" == *"|${feature}|"* ]]
}

select_node_features() {
  local input
  local normalized
  local feature_pattern
  local has_peer
  local has_api
  local has_harvester
  local has_voter

  while true; do
    cat <<'EOF'

Node featuresを指定してください。

  PEER       : Peerノード
  API        : REST APIを公開（Peerも自動的に有効）
  HARVESTER  : ハーベスト機能
  VOTER      : ファイナライズ投票機能

複数指定する場合は | で区切ってください。
例: PEER|HARVESTER、API|HARVESTER、PEER|VOTER
EOF
    read -r -p "features [PEER|HARVESTER]: " input
    input="${input:-PEER|HARVESTER}"
    normalized="$(printf '%s' "$input" | tr -d '[:space:]' | tr ',' '|')"
    normalized="$(printf '%s' "$normalized" | tr '[:lower:]' '[:upper:]')"
    feature_pattern='^(PEER|API|HARVESTER|VOTER)(\|(PEER|API|HARVESTER|VOTER))*$'

    if [[ -z "$normalized" ]] || [[ ! "$normalized" =~ $feature_pattern ]]; then
      warn "featuresを正しい形式で指定してください。"
      continue
    fi

    has_peer=0
    has_api=0
    has_harvester=0
    has_voter=0
    case "|${normalized}|" in *"|PEER|"*) has_peer=1 ;; esac
    case "|${normalized}|" in *"|API|"*) has_api=1 ;; esac
    case "|${normalized}|" in *"|HARVESTER|"*) has_harvester=1 ;; esac
    case "|${normalized}|" in *"|VOTER|"*) has_voter=1 ;; esac

    if ((has_peer == 0 && has_api == 0)); then
      warn "PEERまたはAPIを1つ以上指定してください。"
      continue
    fi

    # APIノードはPeer機能も持つため、設定上も明示する。
    ((has_api == 1)) && has_peer=1

    NODE_FEATURES=""
    ((has_peer == 1)) && NODE_FEATURES="PEER"
    ((has_api == 1)) && NODE_FEATURES="${NODE_FEATURES}|API"
    ((has_harvester == 1)) && NODE_FEATURES="${NODE_FEATURES}|HARVESTER"
    ((has_voter == 1)) && NODE_FEATURES="${NODE_FEATURES}|VOTER"
    return 0
  done
}

select_light_api() {
  local choice

  while true; do
    if feature_enabled API; then
      read -r -p "APIをLight APIとして構成しますか？（nの場合はFull API） [y/N]: " choice
    else
      read -r -p "Light APIを有効にしますか？ [y/N]: " choice
    fi
    choice="${choice:-N}"

    case "$choice" in
      [Yy]|[Yy][Ee][Ss])
        if ! feature_enabled API; then
          NODE_FEATURES="${NODE_FEATURES}|API"
        fi
        LIGHT_API_ENABLED="true"
        return 0
        ;;
      [Nn]|[Nn][Oo])
        LIGHT_API_ENABLED="false"
        return 0
        ;;
      *) warn "yまたはnを入力してください。" ;;
    esac
  done
}

select_beneficiary_address() {
  local choice
  local address
  local normalized

  while true; do
    read -r -p "beneficiaryAddressを指定しますか？ [y/N]: " choice
    choice="${choice:-N}"

    case "$choice" in
      [Yy]|[Yy][Ee][Ss])
        while true; do
          read -r -p "beneficiaryAddress（${NETWORK_NAME}のSymbolアドレス）: " address
          normalized="${address//-/}"

          if [[ "$NETWORK_NAME" == "mainnet" && "$normalized" =~ ^N[A-Z2-7]{38}$ ]] ||
             [[ "$NETWORK_NAME" == "testnet" && "$normalized" =~ ^T[A-Z2-7]{38}$ ]]; then
            BENEFICIARY_ADDRESS="$normalized"
            return
          fi

          warn "${NETWORK_NAME}のSymbolアドレスを入力してください（${NETWORK_NAME}は39文字、ハイフンは任意）。"
        done
        ;;
      [Nn]|[Nn][Oo])
        BENEFICIARY_ADDRESS=""
        return
        ;;
      *) warn "yまたはnを入力してください。" ;;
    esac
  done
}

read_node_identity() {
  local suggested_name="pixel6-symbol-peer"

  while true; do
    read -r -p "外部から到達可能な公開IPまたはドメイン: " NODE_HOST
    if [[ -z "$NODE_HOST" || "$NODE_HOST" =~ [[:space:]] ]]; then
      warn "空白を含まない公開IPまたはドメインを入力してください。"
      continue
    fi
    break
  done

  read -r -p "Friendly Name [${suggested_name}]: " FRIENDLY_NAME
  FRIENDLY_NAME="${FRIENDLY_NAME:-$suggested_name}"
  [[ ! "$FRIENDLY_NAME" =~ [$'\r\n'] ]] || die "Friendly Nameに改行は使用できません。"
}

is_valid_https_hostname() {
  local hostname="$1"

  "${VENV_DIR}/bin/python3" - "$hostname" <<'PY'
import ipaddress
import re
import sys

hostname = sys.argv[1].rstrip('.')
if not hostname or len(hostname) > 253 or '.' not in hostname:
    raise SystemExit(1)
if hostname.lower().endswith(('.local', '.localhost', '.internal', '.lan', '.home')):
    raise SystemExit(1)
try:
    ipaddress.ip_address(hostname)
    raise SystemExit(1)
except ValueError:
    pass
label_pattern = re.compile(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$')
if any(not label_pattern.fullmatch(label) for label in hostname.split('.')):
    raise SystemExit(1)
PY
}

select_api_https() {
  local choice
  local https_host

  if ! feature_enabled API; then
    API_HTTPS_ENABLED="false"
    return
  fi

  while true; do
    read -r -p "API HTTPSを有効にしますか？ [y/N]: " choice
    choice="${choice:-N}"
    case "$choice" in
      [Nn]|[Nn][Oo])
        API_HTTPS_ENABLED="false"
        return
        ;;
      [Yy]|[Yy][Ee][Ss])
        cat <<'EOF'

HTTPSには、このNodeを向いた公開ドメインと事前のDNS設定が必要です。
IPアドレス、localhost、プライベートホスト名は指定できません。
EOF
        https_host="$NODE_HOST"
        while ! is_valid_https_hostname "$https_host"; do
          read -r -p "HTTPSで使用する公開ドメイン: " https_host
          is_valid_https_hostname "$https_host" \
            || { warn "example.comのような有効な公開ドメインを入力してください。"; continue; }
        done
        NODE_HOST="${https_host%.}"
        API_HTTPS_ENABLED="true"
        return
        ;;
      *) warn "yまたはnを入力してください。" ;;
    esac
  done
}

select_account_setup_mode() {
  local choice

  while true; do
    cat <<'EOF'

Nodeアカウントの準備方法を選択してください。
EOF
    if feature_enabled HARVESTER; then
      cat <<'EOF'

  1) main / transport / remote / VRFを新規生成する
  2) main / transport / remote / VRFの既存秘密鍵を指定する
EOF
    else
      cat <<'EOF'

  1) main / transportを新規生成する
  2) main / transportの既存秘密鍵を指定する
EOF
    fi
    read -r -p "番号 [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
      1) ACCOUNT_SETUP_MODE="auto"; return ;;
      2) ACCOUNT_SETUP_MODE="specified"; return ;;
      *) warn "1または2を入力してください。" ;;
    esac
  done
}

prepare_specified_accounts() {
  local key_path
  local main_private_key
  local transport_private_key
  local remote_private_key
  local vrf_private_key
  local main_input
  local transport_input

  NODE_KEY_PATH="${CONFIG_DIR}/node.key.pem"
  HARVESTER_IMPORT_PATH="${CONFIG_DIR}/remotevrf"

  for key_path in "$CA_KEY_PATH" "$NODE_KEY_PATH" "$HARVESTER_IMPORT_PATH"; do
    [[ ! -e "$key_path" ]] || die "既存ファイルは上書きしません: $key_path"
  done

  umask 077
  while true; do
    read -r -p "main秘密鍵（64桁の16進数、入力内容は表示されます）: " main_private_key
    if [[ "$main_private_key" =~ ^[[:xdigit:]]{64}$ ]]; then
      break
    fi
    warn "main秘密鍵は64桁の16進数です。もう一度入力してください。"
  done
  main_input="$(mktemp --tmpdir shoestring-main-key.XXXXXX)"
  printf '%s\n' "$main_private_key" >"$main_input"
  main_private_key=""
  info "main秘密鍵からca.key.pemを作成します。"
  if ! run_as_target "${VENV_DIR}/bin/python3" -m shoestring pemtool --input "$main_input" --output "$CA_KEY_PATH"; then
    rm -f -- "$main_input"; die "ca.key.pemの生成に失敗しました。"
  fi
  rm -f -- "$main_input"
  [[ -f "$CA_KEY_PATH" ]] || die "ca.key.pemが生成されませんでした。"

  while true; do
    read -r -p "transport秘密鍵（64桁の16進数、入力内容は表示されます）: " transport_private_key
    if [[ "$transport_private_key" =~ ^[[:xdigit:]]{64}$ ]]; then
      break
    fi
    warn "transport秘密鍵は64桁の16進数です。もう一度入力してください。"
  done
  transport_input="$(mktemp --tmpdir shoestring-transport-key.XXXXXX)"
  printf '%s\n' "$transport_private_key" >"$transport_input"
  transport_private_key=""
  info "transport秘密鍵からnode.key.pemを作成します。"
  if ! run_as_target "${VENV_DIR}/bin/python3" -m shoestring pemtool --input "$transport_input" --output "$NODE_KEY_PATH"; then
    rm -f -- "$transport_input"; die "node.key.pemの生成に失敗しました。"
  fi
  rm -f -- "$transport_input"
  [[ -f "$NODE_KEY_PATH" ]] || die "node.key.pemが生成されませんでした。"

  if ! feature_enabled HARVESTER; then
    HARVESTER_IMPORT_PATH=""
    chmod 600 "$CA_KEY_PATH" "$NODE_KEY_PATH"
    return
  fi

  while true; do
    read -r -p "remote秘密鍵（64桁の16進数、入力内容は表示されます）: " remote_private_key
    if [[ "$remote_private_key" =~ ^[[:xdigit:]]{64}$ ]]; then
      break
    fi
    warn "remote秘密鍵は64桁の16進数です。もう一度入力してください。"
  done

  while true; do
    read -r -p "VRF秘密鍵（64桁の16進数、入力内容は表示されます）: " vrf_private_key
    if [[ "$vrf_private_key" =~ ^[[:xdigit:]]{64}$ ]]; then
      break
    fi
    warn "VRF秘密鍵は64桁の16進数です。もう一度入力してください。"
  done

  printf '[harvesting]\n\nharvesterSigningPrivateKey = %s\nharvesterVrfPrivateKey = %s\n' \
    "$remote_private_key" "$vrf_private_key" >"$HARVESTER_IMPORT_PATH"
  chmod 600 "$CA_KEY_PATH" "$NODE_KEY_PATH" "$HARVESTER_IMPORT_PATH"
  remote_private_key=""
  vrf_private_key=""
}

prepare_node_configuration() {
  local config_file
  local overrides_file

  # Node生成物はNODE_DIR直下、setup入力はshoestringディレクトリに置く。
  INSTALL_DIR="$NODE_DIR"
  CONFIG_DIR="${NODE_DIR}/shoestring"
  CA_KEY_PATH="${NODE_DIR}/ca.key.pem"
  NODE_KEY_PATH=""
  HARVESTER_IMPORT_PATH=""
  config_file="${CONFIG_DIR}/shoestring.ini"
  overrides_file="${CONFIG_DIR}/overrides.ini"

  if [[ -e "${NODE_DIR}/testnet/docker-compose.yaml" || -e "${NODE_DIR}/mainnet/docker-compose.yaml" ]]; then
    die "旧形式のNodeが ${NODE_DIR}/testnet または ${NODE_DIR}/mainnet にあります。新形式との併設はしません。"
  fi

  if [[ -e "${INSTALL_DIR}/docker-compose.yaml" ]]; then
    die "${NETWORK_NAME} Nodeは既に構築済みです: ${INSTALL_DIR}"
  fi

  if [[ -d "$INSTALL_DIR" ]] && find "$INSTALL_DIR" -mindepth 1 -print -quit | grep -q .; then
    die "未完了または既存のデータが ${INSTALL_DIR} にあります。自動削除はしません。"
  fi

  run_as_target mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

  if [[ "$ACCOUNT_SETUP_MODE" == "specified" ]]; then
    prepare_specified_accounts
  elif [[ ! -e "$CA_KEY_PATH" ]]; then
    info "Remote Harvestingのメインアカウント兼Peer証明書用CA鍵を生成します。"
    run_as_target openssl genpkey -algorithm ed25519 -out "$CA_KEY_PATH"
    chmod 600 "$CA_KEY_PATH"
    if [[ $EUID -eq 0 ]]; then
      chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$CA_KEY_PATH"
    fi
  elif [[ ! -f "$CA_KEY_PATH" ]]; then
    die "CA鍵のパスが通常ファイルではありません: ${CA_KEY_PATH}"
  else
    info "既存のメインアカウント兼Peer証明書用CA鍵を再利用します: ${CA_KEY_PATH}"
  fi

  info "${NETWORK_NAME}のShoestring設定を取得します。"
  run_as_target "${VENV_DIR}/bin/python3" -m shoestring init \
    --package "$NETWORK_PACKAGE" "$config_file"

  run_as_target "${VENV_DIR}/bin/python3" - "$config_file" "$TARGET_USER" "$FRIENDLY_NAME" "$NODE_HOST" \
    "$NODE_FEATURES" "$LIGHT_API_ENABLED" "$API_HTTPS_ENABLED" "$HARVESTER_IMPORT_PATH" "$NODE_KEY_PATH" <<'PY'
import configparser
import os
import sys

filename, username, friendly_name, node_host, features, light_api, api_https, harvester_path, node_key_path = sys.argv[1:]
config = configparser.ConfigParser()
config.optionxform = str
with open(filename, encoding='utf-8') as infile:
    config.read_file(infile)

config['imports']['harvester'] = harvester_path
config['imports']['nodeKey'] = node_key_path
config['node']['features'] = ' | '.join(features.split('|'))
config['node']['apiHttps'] = api_https
config['node']['lightApi'] = light_api
config['node']['caCommonName'] = f'CA {friendly_name}'
config['node']['nodeCommonName'] = f'{friendly_name} {node_host}'

with open(filename, 'w', encoding='utf-8') as outfile:
    config.write(outfile)
os.chmod(filename, 0o600)
PY

  run_as_target "${VENV_DIR}/bin/python3" - "$overrides_file" "$NODE_HOST" "$FRIENDLY_NAME" \
    "$NODE_FEATURES" "$BENEFICIARY_ADDRESS" <<'PY'
import os
import sys

filename, node_host, friendly_name, features, beneficiary_address = sys.argv[1:]
harvesting_settings = ''
if 'HARVESTER' in features.split('|'):
    beneficiary_line = (
        f'beneficiaryAddress = {beneficiary_address}\n'
        if beneficiary_address else ''
    )
    harvesting_settings = f'''[user.account]
enableDelegatedHarvestersAutoDetection = true

[harvesting.harvesting]
maxUnlockedAccounts = 50
{beneficiary_line}
'''

contents = f'''{harvesting_settings}
[node.localnode]
host = {node_host}
friendlyName = {friendly_name}
'''
with open(filename, 'w', encoding='utf-8') as outfile:
    outfile.write(contents)
os.chmod(filename, 0o600)
PY
}

build_node() {
  local config_file="${CONFIG_DIR}/shoestring.ini"
  local overrides_file="${CONFIG_DIR}/overrides.ini"
  local display_features="${NODE_FEATURES//|/ | }"
  local harvesting_status="無効"
  local remote_status="対象外"
  local max_unlocked_accounts="対象外"
  local light_api_status="無効"
  local api_https_status="対象外（API無効）"

  if feature_enabled HARVESTER; then
    harvesting_status="有効"
    remote_status="有効"
    max_unlocked_accounts="50"
  fi
  if [[ "$LIGHT_API_ENABLED" == "true" ]]; then
    light_api_status="有効"
  elif feature_enabled API; then
    light_api_status="無効（Full API）"
  fi
  if feature_enabled API; then
    if [[ "$API_HTTPS_ENABLED" == "true" ]]; then
      api_https_status="有効"
    else
      api_https_status="無効（HTTP）"
    fi
  fi

  cat <<EOF

構築内容
--------------------------------
ネットワーク:              ${NETWORK_NAME}
Node features:             ${display_features}
委任ハーベスト受付:        ${harvesting_status}
Node自身のRemote Harvest:  ${remote_status}
Light API:                  ${light_api_status}
API HTTPS:                  ${api_https_status}
最大委任者数:              ${max_unlocked_accounts}
beneficiaryAddress:        ${BENEFICIARY_ADDRESS:-未指定}
公開IP／ドメイン:          ${NODE_HOST}
Friendly Name:             ${FRIENDLY_NAME}
構築先:                    ${INSTALL_DIR}
--------------------------------
EOF

  confirm "この内容でShoestring setupを実行しますか？" Y || exit 0

  (
    cd "$TARGET_HOME"
    run_as_target "${VENV_DIR}/bin/python3" -m shoestring setup \
      --config "$config_file" \
      --overrides "$overrides_file" \
      --package "$NETWORK_PACKAGE" \
      --directory "$INSTALL_DIR" \
      --ca-key-path "$CA_KEY_PATH"
  )

  [[ -e "${INSTALL_DIR}/docker-compose.yaml" ]] \
    || die "docker-compose.yamlが生成されていません。"
  if [[ "$API_HTTPS_ENABLED" == "true" ]]; then
    [[ -d "${INSTALL_DIR}/https-proxy" ]] \
      || die "API HTTPS用のhttps-proxyが生成されていません。"
  fi

}

show_next_step() {
  local display_features="${NODE_FEATURES//|/ | }"
  local harvesting_status="無効"
  local remote_status="対象外"
  local light_api_status="無効"
  local api_https_status="対象外（API無効）"

  if feature_enabled HARVESTER; then
    harvesting_status="有効（最大50アカウント）"
    remote_status="有効（リンク処理はこのスクリプトの対象外）"
  fi
  if [[ "$LIGHT_API_ENABLED" == "true" ]]; then
    light_api_status="有効"
  elif feature_enabled API; then
    light_api_status="無効（Full API）"
  fi
  if feature_enabled API; then
    if [[ "$API_HTTPS_ENABLED" == "true" ]]; then
      api_https_status="有効"
    else
      api_https_status="無効（HTTP）"
    fi
  fi

  cat <<EOF

============================================================
ShoestringによるNode構築が完了しました。Nodeはまだ起動していません。

ユーザー:        ${TARGET_USER}
仮想環境:        ${VENV_DIR}
Nodeディレクトリ: ${INSTALL_DIR}
ネットワーク:      ${NETWORK_NAME}
Node features:     ${display_features}
委任ハーベスト:    ${harvesting_status}
Remote Harvesting設定: ${remote_status}
Light API:         ${light_api_status}
API HTTPS:         ${api_https_status}

設定を確認してください:

  su - ${TARGET_USER}
  source ~/env/bin/activate
  cd ${INSTALL_DIR}
  docker-compose config

確認後にNodeを起動するには、Nodeディレクトリへ移動してから
docker-compose up -dを実行します:

  cd ${INSTALL_DIR}
  docker-compose up -d

Nodeを停止するには、同じディレクトリでdocker-compose downを実行します:

  cd ${INSTALL_DIR}
  docker-compose down

Docker Composeプラグインを使用する環境では、docker-composeの代わりに
docker composeと入力してください。

バックアップスクリプト:

  ${GENERATED_BACKUP_PATH} --node-dir ${INSTALL_DIR} --output-dir ~/symbol-backups

復元スクリプト:

  ${GENERATED_RESTORE_PATH} --backup ~/symbol-backups/<バックアップファイル>.tar.gz.enc

このスクリプトはリンクトランザクションの署名・アナウンスと
Node起動を行わず、ここで終了します。
============================================================
EOF
}

create_role_copy() {
  local preferred_path="$1"
  local generated_path="$preferred_path"

  if [[ -e "$preferred_path" ]]; then
    if cmp -s "$SCRIPT_PATH" "$preferred_path"; then
      printf '%s\n' "$preferred_path"
      return
    fi

    generated_path="${preferred_path%.sh}-$(date -u +%Y%m%dT%H%M%SZ).sh"
    warn "既存ファイルは上書きせず、新しい名前で生成します: $generated_path"
  fi

  cp -p "$SCRIPT_PATH" "$generated_path"
  chmod 700 "$generated_path"
  if [[ $EUID -eq 0 && -n "$TARGET_USER" ]]; then
    chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$generated_path"
  fi
  printf '%s\n' "$generated_path"
}

generate_management_scripts() {
  GENERATED_BUILD_PATH="$(create_role_copy "${TARGET_HOME}/build-symbol-shoestring-node.sh")"
  GENERATED_BACKUP_PATH="$(create_role_copy "${TARGET_HOME}/backup-symbol-shoestring.sh")"
  GENERATED_RESTORE_PATH="$(create_role_copy "${TARGET_HOME}/restore-symbol-shoestring.sh")"
  GENERATED_SNAPSHOT_PATH="$(create_role_copy "${TARGET_HOME}/sync-symbol-shoestring-snapshot.sh")"

  info "管理用スクリプトを生成しました:"
  printf '  %s\n' "$GENERATED_BUILD_PATH" "$GENERATED_BACKUP_PATH" \
    "$GENERATED_RESTORE_PATH" "$GENERATED_SNAPSHOT_PATH"
}

show_manual_build_guide() {
  cat <<EOF

手動でNodeを構築する場合:

  su - ${TARGET_USER}
  source ~/env/bin/activate
  cd ~/symbolNode
  python3 -m shoestring.wizard

インストール処理は完了しています。
EOF
}

choose_build_method() {
  local choice
  local build_script

  while true; do
    cat <<'EOF'

Nodeの構築方法を選択してください。

  1) Node構築スクリプトを起動する
  2) Shoestring Wizardで手動構築する
  3) 今は構築せず終了する
EOF
    read -r -p "番号 [3]: " choice
    choice="${choice:-3}"

    case "$choice" in
      1)
        build_script="$GENERATED_BUILD_PATH"
        info "Node構築スクリプトを起動します: $build_script"
        run_as_target bash "$build_script" --build-node
        return
        ;;
      2)
        show_manual_build_guide
        return
        ;;
      3)
        info "Node構築は行わず終了します。"
        return
        ;;
      *) warn "1、2、3のいずれかを入力してください。" ;;
    esac
  done
}

installer_main() {
  self_elevate "$@"
  check_platform

  cat <<'EOF'

Symbol Shoestring セットアップ
--------------------------------
新規ユーザー、Docker、Docker Compose、Python仮想環境、
symbol-shoestringを準備します。インストール完了後に、
自動構築、Wizardによる手動構築、終了のいずれかを選択できます。
既存のユーザーや環境は、確認なしに削除・上書きしません。
EOF

  confirm "この内容でセットアップを開始しますか？" Y || exit 0
  select_user
  generate_management_scripts
  install_docker
  install_shoestring_dependencies
  install_docker_compose
  prepare_virtualenv
  prepare_node_directory
  choose_build_method
}

build_main() {
  [[ $EUID -ne 0 ]] || die "Node構築スクリプトはrootではなくNode運用ユーザーで実行してください。"

  TARGET_USER="$(id -un)"
  TARGET_HOME="$HOME"
  VENV_DIR="${TARGET_HOME}/env"
  NODE_DIR="${TARGET_HOME}/symbolNode"

  [[ -x "${VENV_DIR}/bin/python3" ]] || die "Python仮想環境が見つかりません: $VENV_DIR"
  "${VENV_DIR}/bin/python3" -m shoestring --help >/dev/null \
    || die "symbol-shoestringを確認できません。先にインストールスクリプトを完了してください。"

  mkdir -p "$NODE_DIR"
  generate_management_scripts

  select_network
  select_node_features
  select_light_api
  if feature_enabled HARVESTER; then
    select_beneficiary_address
  else
    BENEFICIARY_ADDRESS=""
  fi
  read_node_identity
  select_api_https
  select_account_setup_mode
  prepare_node_configuration
  build_node
  show_next_step
}

snapshot_cleanup() {
  [[ -z "$SNAPSHOT_WORK_DIR" ]] || rm -rf -- "$SNAPSHOT_WORK_DIR"
}

snapshot_preserve() {
  trap - EXIT INT TERM
  warn "処理を中断しました。一時ファイルを保持します: $SNAPSHOT_WORK_DIR"
  exit 130
}

snapshot_usage() {
  cat <<'EOF'
Usage:
  ./sync-symbol-shoestring-snapshot.sh [--node-dir PATH] [--url URL]

Options:
  --node-dir PATH  Shoestring Nodeディレクトリ（既定: ~/symbolNode）
  --url URL        mainnet PeerスナップショットURL
  -h, --help       ヘルプを表示
EOF
}

snapshot_main() {
  local node_dir="${HOME}/symbolNode"
  local snapshot_url="https://catapultmainnetdata.s3.us-west-2.amazonaws.com/weekly/catapult_peer_data.tar.gz"
  local config_file config_state network_name node_features running confirmation archive_path snapshot_data_path strip_components
  local snapshot_parent resume_dir candidate candidate_url
  local harvesters_backup
  local compose=()

  while (($#)); do
    case "$1" in
      --node-dir) (($# >= 2)) || die "--node-dirにはパスが必要です。"; node_dir="$2"; shift 2 ;;
      --url) (($# >= 2)) || die "--urlにはURLが必要です。"; snapshot_url="$2"; shift 2 ;;
      -h|--help) snapshot_usage; return ;;
      *) die "不明なオプションです: $1" ;;
    esac
  done

  [[ $EUID -ne 0 ]] || die "Node運用ユーザーで実行してください。"
  command -v curl >/dev/null || die "curlが見つかりません。"
  command -v python3 >/dev/null || die "python3が見つかりません。"
  node_dir="$(readlink -f "$node_dir")"
  [[ "$node_dir" != "/" && -f "${node_dir}/docker-compose.yaml" ]] || die "有効なNodeディレクトリではありません: $node_dir"
  [[ -d "${node_dir}/data" ]] || die "dataディレクトリが見つかりません: ${node_dir}/data"
  config_file="${node_dir}/shoestring/shoestring.ini"
  [[ -f "$config_file" ]] || die "shoestring.iniが見つかりません: $config_file"
  config_state="$(python3 - "$config_file" <<'PY'
import configparser, sys
c = configparser.ConfigParser()
c.read(sys.argv[1], encoding='utf-8')
network = c.get('network', 'name', fallback='').strip().lower()
features = c.get('node', 'features', fallback='').strip().upper().replace(' ', '')
print(f'{network}\t{features}')
PY
)" || die "ネットワーク設定を読み取れません。"
  network_name="${config_state%%$'\t'*}"
  node_features="${config_state#*$'\t'}"
  [[ "$network_name" == "mainnet" ]] || die "mainnet Peer以外では実行できません。"
  [[ "|${node_features}|" == *"|PEER|"* ]] || die "mainnet Peer以外では実行できません。"

  if command -v docker-compose >/dev/null 2>&1; then compose=(docker-compose)
  elif docker compose version >/dev/null 2>&1; then compose=(docker compose)
  else die "Docker Composeが見つかりません。"; fi
  running="$("${compose[@]}" -f "${node_dir}/docker-compose.yaml" ps -q 2>/dev/null)" \
    || die "Nodeの停止状態を確認できません。"
  [[ -z "$running" ]] || die "Nodeが稼働中です。先に停止してください。"

  printf '\nNode: %s\nURL: %s\n' "$node_dir" "$snapshot_url"
  warn "準備完了後、既存のdataを削除して置き換えます。"
  read -r -p "続行する場合は mainnet-snapshot と入力: " confirmation
  [[ "$confirmation" == "mainnet-snapshot" ]] || die "キャンセルしました。"

  snapshot_parent="$(dirname "$node_dir")"
  resume_dir=""
  for candidate in "$snapshot_parent"/.symbol-snapshot.*; do
    [[ -d "$candidate" && -f "${candidate}/snapshot.tar.gz" ]] || continue
    if [[ -f "${candidate}/snapshot.url" ]]; then
      candidate_url="$(<"${candidate}/snapshot.url")"
      [[ "$candidate_url" == "$snapshot_url" ]] || continue
    fi
    if [[ -z "$resume_dir" || "$candidate" -nt "$resume_dir" ]]; then
      resume_dir="$candidate"
    fi
  done

  SNAPSHOT_WORK_DIR=""
  if [[ -n "$resume_dir" ]] && confirm "途中のスナップショットを再利用しますか？ [$resume_dir]" Y; then
    SNAPSHOT_WORK_DIR="$resume_dir"
    info "途中のスナップショットを再利用します。"
  else
    SNAPSHOT_WORK_DIR="$(mktemp -d --tmpdir="$snapshot_parent" .symbol-snapshot.XXXXXX)"
  fi
  printf '%s\n' "$snapshot_url" >"${SNAPSHOT_WORK_DIR}/snapshot.url"
  trap snapshot_cleanup EXIT
  trap snapshot_preserve INT TERM
  archive_path="${SNAPSHOT_WORK_DIR}/snapshot.tar.gz"
  info "スナップショットをダウンロードします。"
  if ! curl --fail --location --retry 5 --retry-delay 5 --continue-at - \
    --output "$archive_path" "$snapshot_url"; then
    if tar -tzf "$archive_path" >/dev/null 2>&1; then
      info "既存のスナップショットはダウンロード済みとして続行します。"
    else
      trap - EXIT INT TERM
      warn "ダウンロードに失敗しました。一時ファイルを保持します: $SNAPSHOT_WORK_DIR"
      exit 1
    fi
  fi
  [[ -s "$archive_path" ]] || die "アーカイブが空です。"
  snapshot_data_path="$(
    set +o pipefail
    tar -tzf "$archive_path" 2>/dev/null \
      | awk '{ sub(/\/$/, ""); if ($0 == "data" || $0 ~ /\/data$/) { print; exit } }'
  )"
  if [[ -z "$snapshot_data_path" || "$snapshot_data_path" == /* || "$snapshot_data_path" == *"../"* ]]; then
    trap - EXIT INT TERM
    warn "スナップショット内のdataを確認できません。アーカイブを保持します: $SNAPSHOT_WORK_DIR"
    exit 1
  fi
  strip_components="$(awk -F/ '{ print NF - 1 }' <<<"$snapshot_data_path")"

  harvesters_backup="${SNAPSHOT_WORK_DIR}/harvesters.dat"
  if [[ -f "${node_dir}/data/harvesters.dat" ]]; then
    cp -p "${node_dir}/data/harvesters.dat" "$harvesters_backup"
  else
    info "harvesters.datはありません。復元なしで続行します。"
  fi
  rm -rf -- "${node_dir}/data"
  info "スナップショットのdataをNodeディレクトリへ直接展開します。"
  if ! tar --no-same-owner --strip-components="$strip_components" \
    -xzf "$archive_path" -C "$node_dir" -- "$snapshot_data_path"; then
    trap - EXIT INT TERM
    warn "展開に失敗しました。アーカイブとharvesters.datの退避ファイルを保持します: $SNAPSHOT_WORK_DIR"
    exit 1
  fi
  if [[ ! -d "${node_dir}/data" ]]; then
    trap - EXIT INT TERM
    warn "展開後のdataを確認できません。一時ファイルを保持します: $SNAPSHOT_WORK_DIR"
    exit 1
  fi
  [[ ! -f "$harvesters_backup" ]] || cp -p "$harvesters_backup" "${node_dir}/data/harvesters.dat"
  trap - EXIT INT TERM
  snapshot_cleanup
  SNAPSHOT_WORK_DIR=""
  info "スナップショットを配置しました。Nodeは自動起動していません。"
}

backup_cleanup() {
  [[ -z "$BACKUP_TEMP_ARCHIVE" ]] || rm -f "$BACKUP_TEMP_ARCHIVE"
}

backup_usage() {
  cat <<'EOF'
Usage:
  ./backup-symbol-shoestring.sh [--node-dir PATH] [--output-dir PATH]

Options:
  --node-dir PATH    Shoestring Nodeディレクトリ
  --output-dir PATH  暗号化バックアップ保存先（既定: ~/symbol-backups）
  -h, --help         ヘルプを表示
EOF
}

backup_main() {
  local backup_node_dir=""
  local output_dir="${HOME}/symbol-backups"
  local symbol_root
  local network_name
  local compose=()
  local running
  local timestamp
  local archive_base
  local encrypted_file
  local checksum_file
  local contents_file
  local candidate
  local choice
  local relative
  local items=()
  local candidates=()

  while (($#)); do
    case "$1" in
      --node-dir) (($# >= 2)) || die "--node-dirにはパスが必要です。"; backup_node_dir="$2"; shift 2 ;;
      --output-dir) (($# >= 2)) || die "--output-dirにはパスが必要です。"; output_dir="$2"; shift 2 ;;
      -h|--help) backup_usage; return ;;
      *) die "不明なオプションです: $1" ;;
    esac
  done

  if [[ -z "$backup_node_dir" ]]; then
    for candidate in "${HOME}/symbolNode" "${HOME}/symbolNode/testnet" "${HOME}/symbolNode/mainnet"; do
      [[ -f "${candidate}/docker-compose.yaml" ]] && candidates+=("$candidate")
    done

    if ((${#candidates[@]} == 1)); then
      backup_node_dir="${candidates[0]}"
    elif ((${#candidates[@]} > 1)); then
      printf '\nバックアップするNodeを選択してください。\n'
      for candidate in "${!candidates[@]}"; do
        printf '  %d) %s\n' "$((candidate + 1))" "${candidates[$candidate]}"
      done
      read -r -p "番号: " choice
      [[ "$choice" =~ ^[0-9]+$ ]] || die "番号を入力してください。"
      ((choice >= 1 && choice <= ${#candidates[@]})) || die "選択範囲外です。"
      backup_node_dir="${candidates[$((choice - 1))]}"
    else
      read -r -p "Shoestring Nodeディレクトリ: " backup_node_dir
    fi
  fi

  backup_node_dir="$(readlink -f "$backup_node_dir")"
  [[ -f "${backup_node_dir}/docker-compose.yaml" ]] \
    || die "docker-compose.yamlが見つかりません: $backup_node_dir"

  network_name="$(basename "$backup_node_dir")"
  case "$network_name" in
    testnet|mainnet) symbol_root="$(dirname "$backup_node_dir")" ;;
    *) network_name="node"; symbol_root="$backup_node_dir" ;;
  esac

  if command -v docker-compose >/dev/null 2>&1; then
    compose=(docker-compose)
  elif docker compose version >/dev/null 2>&1; then
    compose=(docker compose)
  else
    die "Docker Composeが見つかりません。"
  fi

  if ! running="$("${compose[@]}" -f "${backup_node_dir}/docker-compose.yaml" ps -q 2>/dev/null)"; then
    die "Nodeの停止状態を確認できません。Docker権限を確認してください。"
  fi
  [[ -z "$running" ]] \
    || die "Nodeが動作中です。正常停止してください: cd '$backup_node_dir' && ${compose[*]} down"

  backup_add() {
    local path="$1"
    [[ -e "$path" ]] || return
    case "$path" in
      "$symbol_root"/*) relative="${path#"$symbol_root"/}" ;;
      *) die "対象がSymbolルート外です: $path" ;;
    esac
    items+=("$relative")
  }

  backup_add "${backup_node_dir}/docker-compose.yaml"
  backup_add "${backup_node_dir}/docker-compose-recovery.yaml"
  backup_add "${backup_node_dir}/shoestring"
  backup_add "${backup_node_dir}/userconfig"
  backup_add "${backup_node_dir}/keys"
  backup_add "${backup_node_dir}/data/harvesters.dat"
  if [[ "$network_name" != "node" ]]; then
    backup_add "${symbol_root}/config/${network_name}"
    backup_add "${symbol_root}/keys/${network_name}-ca.key.pem"
  else
    backup_add "${backup_node_dir}/ca.key.pem"
  fi

  [[ -f "${backup_node_dir}/data/harvesters.dat" ]] \
    || warn "harvesters.datはまだ存在しません。"
  ((${#items[@]} > 0)) || die "バックアップ対象がありません。"

  output_dir="$(realpath -m "$output_dir")"
  mkdir -p "$output_dir"
  [[ -w "$output_dir" ]] || die "保存先へ書き込めません: $output_dir"

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  archive_base="symbol-shoestring-${network_name}-${timestamp}"
  encrypted_file="${output_dir}/${archive_base}.tar.gz.enc"
  checksum_file="${encrypted_file}.sha256"
  contents_file="${output_dir}/${archive_base}.contents.txt"
  BACKUP_TEMP_ARCHIVE="$(mktemp --tmpdir symbol-shoestring-backup.XXXXXX.tar.gz)"
  trap backup_cleanup EXIT INT TERM

  info "以下をバックアップします。"
  printf '  %s\n' "${items[@]}"
  tar --acls --xattrs --numeric-owner -C "$symbol_root" -czf "$BACKUP_TEMP_ARCHIVE" -- "${items[@]}"

  {
    printf 'created_utc=%s\nsource_root=%s\nnode_directory=%s\nnetwork=%s\n\ncontents:\n' \
      "$timestamp" "$symbol_root" "$backup_node_dir" "$network_name"
    printf '%s\n' "${items[@]}"
  } >"$contents_file"
  chmod 600 "$contents_file"

  info "暗号化パスワードを2回入力してください。"
  openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 \
    -in "$BACKUP_TEMP_ARCHIVE" -out "$encrypted_file"
  chmod 600 "$encrypted_file"
  (cd "$output_dir" && sha256sum "$(basename "$encrypted_file")" >"$(basename "$checksum_file")")
  chmod 600 "$checksum_file"
  backup_cleanup
  BACKUP_TEMP_ARCHIVE=""
  trap - EXIT INT TERM

  printf '\n暗号化バックアップ: %s\nチェックサム: %s\n内容一覧: %s\n' \
    "$encrypted_file" "$checksum_file" "$contents_file"

  GENERATED_RESTORE_PATH="$(create_role_copy "${symbol_root}/restore-symbol-shoestring.sh")"
  printf '復元スクリプト: %s\n' "$GENERATED_RESTORE_PATH"
  printf '復元コマンド: %q --backup %q\n' "$GENERATED_RESTORE_PATH" "$encrypted_file"
}

restore_cleanup() {
  [[ -z "$RESTORE_TEMP_ARCHIVE" ]] || rm -f "$RESTORE_TEMP_ARCHIVE"
}

restore_usage() {
  cat <<'EOF'
Usage:
  ./restore-symbol-shoestring.sh --backup FILE [--target-root PATH]

Options:
  --backup FILE       backup-symbol-shoestring.shが作成した.tar.gz.encファイル
  --target-root PATH  復元先のSymbolルート（既定: ~/symbolNode）
  -h, --help          ヘルプを表示
EOF
}

prepare_compose_bind_directories() {
  local node_dir="$1"
  local compose_file="${node_dir}/docker-compose.yaml"
  local bind_dir
  local -a bind_dirs=()

  mapfile -t bind_dirs < <(python3 - "$compose_file" "$node_dir" <<'PY'
import pathlib
import re
import sys

compose_path = pathlib.Path(sys.argv[1])
node_dir = pathlib.Path(sys.argv[2]).resolve()

short_syntax = re.compile(r'^\s*-\s+([^:]+)\s*:\s*/')
long_syntax = re.compile(r'^\s*source\s*:\s*(\S+)')
directories = set()

for line in compose_path.read_text(encoding='utf-8').splitlines():
    match = short_syntax.match(line) or long_syntax.match(line)
    if not match:
        continue

    source = match.group(1).strip().strip(chr(34) + chr(39))
    if '$' in source or source.startswith('~'):
        continue

    source_path = pathlib.Path(source)
    if not source_path.is_absolute() and not source.startswith(('./', '../')):
        continue
    candidate = source_path.resolve() if source_path.is_absolute() else (node_dir / source_path).resolve()
    try:
        candidate.relative_to(node_dir)
    except ValueError:
        continue
    directories.add(candidate)

for directory in sorted(directories):
    print(directory)
PY
  )

  for bind_dir in "${bind_dirs[@]}"; do
    [[ ! -f "$bind_dir" ]] || continue
    if [[ -e "$bind_dir" && ! -d "$bind_dir" ]]; then
      die "Composeのマウント元がディレクトリではありません: $bind_dir"
    fi
    mkdir -p "$bind_dir"
    [[ -w "$bind_dir" ]] \
      || die "Composeのマウント元へ書き込めません。所有者と権限を確認してください: $bind_dir"
  done

  ((${#bind_dirs[@]} == 0)) \
    || info "Compose構成に必要なディレクトリを確認・作成しました。"
}

restore_main() {
  local encrypted_file=""
  local target_root="${HOME}/symbolNode"
  local checksum_file
  local expected_checksum
  local actual_checksum
  local network_name
  local node_dir
  local overwrite_existing="false"

  while (($#)); do
    case "$1" in
      --backup)
        (($# >= 2)) || die "--backupにはファイルパスが必要です。"
        encrypted_file="$2"
        shift 2
        ;;
      --target-root)
        (($# >= 2)) || die "--target-rootにはパスが必要です。"
        target_root="$2"
        shift 2
        ;;
      -h|--help)
        restore_usage
        return
        ;;
      *) die "不明なオプションです: $1" ;;
    esac
  done

  [[ $EUID -ne 0 ]] \
    || die "復元スクリプトはrootではなくNode運用ユーザーで実行してください。"
  TARGET_USER="$(id -un)"
  TARGET_HOME="$HOME"
  [[ -n "$encrypted_file" ]] || die "--backupで暗号化バックアップを指定してください。"
  encrypted_file="$(readlink -f "$encrypted_file")"
  [[ -f "$encrypted_file" ]] || die "バックアップファイルが見つかりません: $encrypted_file"

  checksum_file="${encrypted_file}.sha256"
  [[ -f "$checksum_file" ]] || die "チェックサムファイルが見つかりません: $checksum_file"
  command -v openssl >/dev/null || die "opensslが見つかりません。"
  command -v sha256sum >/dev/null || die "sha256sumが見つかりません。"
  command -v tar >/dev/null || die "tarが見つかりません。"
  command -v python3 >/dev/null || die "python3が見つかりません。"

  read -r expected_checksum _ <"$checksum_file"
  [[ "$expected_checksum" =~ ^[[:xdigit:]]{64}$ ]] \
    || die "チェックサムファイルの形式が不正です: $checksum_file"
  actual_checksum="$(sha256sum "$encrypted_file" | cut -d' ' -f1)"
  [[ "${actual_checksum,,}" == "${expected_checksum,,}" ]] \
    || die "バックアップのチェックサムが一致しません。破損または改変の可能性があります。"
  info "バックアップのチェックサムを確認しました。"

  RESTORE_TEMP_ARCHIVE="$(mktemp --tmpdir symbol-shoestring-restore.XXXXXX.tar.gz)"
  trap restore_cleanup EXIT INT TERM

  info "バックアップの暗号化パスワードを入力してください。"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
    -in "$encrypted_file" -out "$RESTORE_TEMP_ARCHIVE"

  network_name="$(python3 - "$RESTORE_TEMP_ARCHIVE" <<'PY'
import pathlib
import sys
import tarfile

archive_path = sys.argv[1]
networks = []

try:
    with tarfile.open(archive_path, mode='r:gz') as archive:
        members = archive.getmembers()
        if not members:
            raise ValueError('アーカイブが空です。')

        for member in members:
            path = pathlib.PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts:
                raise ValueError(f'安全でないパスが含まれています: {member.name}')
            if member.issym() or member.islnk() or member.isdev() or member.isfifo():
                raise ValueError(f'復元対象外のファイル形式です: {member.name}')
            if not (member.isfile() or member.isdir()):
                raise ValueError(f'不明なファイル形式です: {member.name}')

            normalized = path.as_posix()
            if normalized.startswith('./'):
                normalized = normalized[2:]
            if normalized == 'testnet/docker-compose.yaml':
                networks.append('testnet')
            elif normalized == 'mainnet/docker-compose.yaml':
                networks.append('mainnet')
            elif normalized == 'docker-compose.yaml':
                networks.append('node')
except (OSError, tarfile.TarError, ValueError) as exc:
    print(f'アーカイブの検査に失敗しました: {exc}', file=sys.stderr)
    raise SystemExit(1)

networks = sorted(set(networks))
if len(networks) != 1:
    print('Node構成を一意に判定できません。', file=sys.stderr)
    raise SystemExit(1)
print(networks[0])
PY
)" || die "バックアップの内容を安全に検査できませんでした。"

  target_root="$(realpath -m "$target_root")"
  if [[ "$network_name" == "node" ]]; then
    node_dir="$target_root"
  else
    node_dir="${target_root}/${network_name}"
  fi

  if [[ -e "$target_root" ]]; then
    warn "復元先に既存のNode構成があります: $target_root"
    overwrite_existing="true"
  fi

  cat <<EOF

復元内容
--------------------------------
バックアップ: ${encrypted_file}
ネットワーク: ${network_name}
復元先:       ${target_root}
--------------------------------

既存ファイル:   $([[ "$overwrite_existing" == "true" ]] && printf '同名ファイルを上書き' || printf 'なし')
復元後もNodeは自動起動しません。
EOF
  if [[ "$overwrite_existing" == "true" ]]; then
    confirm "バックアップ内の同名ファイルを上書きして復元を続けますか？" N || exit 0
  else
    confirm "このバックアップを復元しますか？" N || exit 0
  fi

  mkdir -p "$target_root"
  tar --no-same-owner --overwrite -xzf "$RESTORE_TEMP_ARCHIVE" -C "$target_root"
  [[ -f "${node_dir}/docker-compose.yaml" ]] \
    || die "復元後にdocker-compose.yamlを確認できません: $node_dir"
  prepare_compose_bind_directories "$node_dir"
  generate_management_scripts

  restore_cleanup
  RESTORE_TEMP_ARCHIVE=""
  trap - EXIT INT TERM

  cat <<EOF

============================================================
バックアップを復元しました。Nodeはまだ起動していません。

設定確認:
  cd ${node_dir}
  docker-compose config

Node起動:
  cd ${node_dir}
  docker-compose up -d

Node停止:
  cd ${node_dir}
  docker-compose down

Docker Composeプラグインを使用する環境では、docker-composeの代わりに
docker composeと入力してください。
============================================================
EOF
}

dispatch_main() {
  local mode="install"

  case "$SCRIPT_NAME" in
    build-symbol-shoestring-node*.sh) mode="build" ;;
    backup-symbol-shoestring*.sh) mode="backup" ;;
    restore-symbol-shoestring*.sh) mode="restore" ;;
    sync-symbol-shoestring-snapshot*.sh) mode="snapshot" ;;
  esac

  if [[ "${1:-}" == "--build-node" ]]; then
    mode="build"
    shift
  elif [[ "${1:-}" == "--backup-node" ]]; then
    mode="backup"
    shift
  elif [[ "${1:-}" == "--restore-node" ]]; then
    mode="restore"
    shift
  elif [[ "${1:-}" == "--sync-snapshot" ]]; then
    mode="snapshot"
    shift
  fi

  case "$mode" in
    install) installer_main "$@" ;;
    build) build_main "$@" ;;
    backup) backup_main "$@" ;;
    restore) restore_main "$@" ;;
    snapshot) snapshot_main "$@" ;;
  esac
}

dispatch_main "$@"
